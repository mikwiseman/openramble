import Foundation

/// Rebuild Apple's IPS structure from an allowlist. In particular, exception
/// messages, ASI, queues, thread names, device IDs and unknown fields can carry
/// user content. Never copy them, even when Apple adds fields in a later OS.
enum CrashReportSanitizer {
    private static let cliIdentifiers = ["is.waiwai.dictation.cli", "is.waiwai.dictation.dev.cli"]
    private static let bundles = ["is.waiwai.dictation", "is.waiwai.dictation.dev"] + cliIdentifiers
    private static let processNames = ["OpenRamble", "OpenRambleDev", "openramble-cli"]

    static func sanitize(_ data: Data) throws -> Data? {
        guard let newline = data.firstIndex(of: 10) else { throw CocoaError(.fileReadCorruptFile) }
        guard let header = try JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              let body = try JSONSerialization.jsonObject(with: data[(newline + 1)...]) as? [String: Any],
              let process = body["procName"] as? String, processNames.contains(process),
              (header["bug_type"] as? String) == "309",
              body["threads"] is [Any], body["usedImages"] is [Any] else { return nil }
        let bundle = body["bundleInfo"] as? [String: Any] ?? [:]
        // Command-line executables have no bundleInfo. Their fixed signing
        // identifier is the app-owned identity; the filename alone is not.
        let signedCLI = process == "openramble-cli"
            ? (body["codeSigningID"] as? String).flatMap { cliIdentifiers.contains($0) ? $0 : nil }
            : nil
        guard let identifier = bundle["CFBundleIdentifier"] as? String ?? signedCLI,
              bundles.contains(identifier) else { return nil }
        if let headerBundle = header["bundleID"] as? String, headerBundle != identifier { return nil }

        var safeHeader: [String: Any] = ["app_name": process, "bundleID": identifier]
        copyStrings(header, to: &safeHeader, keys: ["app_version", "build_version", "bug_type"], pattern: #"^[0-9A-Za-z.-]{1,32}$"#)
        copyStrings(header, to: &safeHeader, keys: ["slice_uuid"], pattern: uuidPattern)
        copyStrings(header, to: &safeHeader, keys: ["timestamp"], pattern: datePattern)
        var safe: [String: Any] = ["procName": process, "procPath": "/redacted/\(process)"]
        var safeBundle: [String: Any] = ["CFBundleIdentifier": identifier]
        copyStrings(bundle, to: &safeBundle, keys: ["CFBundleVersion", "CFBundleShortVersionString"], pattern: #"^[0-9A-Za-z.-]{1,32}$"#)
        safe["bundleInfo"] = safeBundle
        copyNumbers(body, to: &safe, keys: ["version", "pid", "uptime", "faultingThread", "translated"])
        copyStrings(body, to: &safe, keys: ["captureTime", "procLaunch"], pattern: datePattern)
        copyStrings(body, to: &safe, keys: ["cpuType"], pattern: #"^(ARM-64|ARM64|X86-64|X86_64)$"#)
        if let os = body["osVersion"] as? [String: Any] {
            var value: [String: Any] = [:]
            copyStrings(os, to: &value, keys: ["train"], pattern: #"^macOS [0-9.]{1,12}$"#)
            copyStrings(os, to: &value, keys: ["build"], pattern: #"^[0-9]{1,3}[A-Z][0-9A-Za-z]{1,12}$"#)
            copyStrings(os, to: &value, keys: ["releaseType"], pattern: #"^(User|Beta|Internal)$"#)
            safe["osVersion"] = value
        }
        if let exception = body["exception"] as? [String: Any] {
            var value: [String: Any] = [:]
            copyStrings(exception, to: &value, keys: ["type"], pattern: #"^EXC_[A-Z_]{1,40}$"#)
            copyStrings(exception, to: &value, keys: ["signal"], pattern: #"^SIG[A-Z]{1,20}$"#)
            copyStrings(exception, to: &value, keys: ["codes"], pattern: #"^[0-9a-fA-Fx, -]{1,150}$"#)
            copyStrings(exception, to: &value, keys: ["subtype"], pattern: #"^KERN_[A-Z_]+( at 0x[0-9a-fA-F]+)?$"#)
            if let codes = exception["rawCodes"] as? [NSNumber] { value["rawCodes"] = codes }
            safe["exception"] = value
        }
        if let termination = body["termination"] as? [String: Any] {
            var value: [String: Any] = [:]
            copyNumbers(termination, to: &value, keys: ["code", "flags"])
            copyStrings(termination, to: &value, keys: ["namespace"], pattern: #"^(SIGNAL|CODESIGNING|DYLD|RUNNINGBOARD|TCC|WATCHDOG|LIBSYSTEM|GUARD|ENDPOINTSECURITY|FRONTBOARD|SPRINGBOARD|CPP)$"#)
            safe["termination"] = value
        }
        // Preserve array positions: frames refer to images by their index.
        safe["usedImages"] = (body["usedImages"] as? [Any] ?? []).map { sanitizeImage($0 as? [String: Any] ?? [:]) }
        safe["threads"] = (body["threads"] as? [Any] ?? []).map { raw in
            let thread = raw as? [String: Any] ?? [:]
            var value: [String: Any] = [:]
            copyNumbers(thread, to: &value, keys: ["id", "triggered"])
            value["frames"] = (thread["frames"] as? [[String: Any]] ?? []).map { frame in
                var cleaned: [String: Any] = [:]
                copyNumbers(frame, to: &cleaned, keys: ["imageIndex", "imageOffset", "symbolLocation"])
                // Symbols are code identifiers, not exception text. Reject paths,
                // URLs, emails and control characters rather than copying them.
                copyStrings(frame, to: &cleaned, keys: ["symbol"], pattern: #"^[A-Za-z_$+\-][A-Za-z0-9_$+\- .:,;<>\[\]()~*&?=!{}#]{0,1023}$"#)
                return cleaned
            }
            if let state = thread["threadState"] as? [String: Any] { value["threadState"] = registers(state) }
            return value
        }
        // These two OS-authored notes explain the incomplete report seen in the
        // field. Other free-form notes are intentionally not exported.
        let knownNotes = ["Corpse is incomplete (_dyld_process_info_create failed with 5)",
                          "Backtraces may be be unvailable or truncated to only leaf frames, and the binary image list may not be available"]
        if let notes = body["reportNotes"] as? [String] {
            safe["reportNotes"] = notes.filter { knownNotes.contains($0) }
        }
        var result = try JSONSerialization.data(withJSONObject: safeHeader, options: [.sortedKeys])
        result.append(10)
        result.append(try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]))
        return result
    }

    private static let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    private static let datePattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:. +Z-]{8,32}$"#

    private static func copyNumbers(_ source: [String: Any], to target: inout [String: Any], keys: [String]) {
        for key in keys { if let value = source[key] as? NSNumber { target[key] = value } }
    }

    private static func copyStrings(_ source: [String: Any], to target: inout [String: Any], keys: [String], pattern: String) {
        for key in keys {
            if let value = source[key] as? String,
               value.range(of: pattern, options: .regularExpression) != nil { target[key] = value }
        }
    }

    private static func sanitizeImage(_ image: [String: Any]) -> [String: Any] {
        var value: [String: Any] = [:]
        copyNumbers(image, to: &value, keys: ["base", "size"])
        copyStrings(image, to: &value, keys: ["uuid"], pattern: uuidPattern)
        copyStrings(image, to: &value, keys: ["arch"], pattern: #"^(arm64e?|x86_64h?)$"#)
        copyStrings(image, to: &value, keys: ["source"], pattern: #"^[PSAC]$"#)
        // Binary UUIDs and offsets survive even when a third-party path must go.
        let imageName = "image-" + (value["uuid"] as? String ?? "unknown")
        value["name"] = imageName
        value["path"] = "/redacted/" + imageName
        if let path = image["path"] as? String, !path.contains(".."),
           path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/lib/") {
            value["path"] = path
            value["name"] = URL(fileURLWithPath: path).lastPathComponent
        } else if let path = image["path"] as? String,
                  let component = path.components(separatedBy: "/").last,
                  ["OpenRamble", "OpenRambleDev", "openramble-cli", "CTranscribe", "Sparkle", "Autoupdate", "Updater", "Downloader", "Installer"].contains(component) {
            value["name"] = component
            value["path"] = "/redacted/" + component
            // UUID lookup does not depend on where the app was installed.
        }
        return value
    }

    private static func registers(_ source: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        copyStrings(source, to: &result, keys: ["flavor"], pattern: #"^(ARM_THREAD_STATE64|x86_THREAD_STATE|x86_THREAD_STATE64)$"#)
        let keys = ["fp", "lr", "sp", "pc", "cpsr", "far", "esr", "rax", "rbx", "rcx", "rdx", "rdi", "rsi", "rbp", "rsp", "rip", "rflags", "cs", "fs", "gs", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
        for key in keys {
            if let register = source[key] as? [String: Any], let value = register["value"] as? NSNumber {
                result[key] = ["value": value]
            }
        }
        if let registers = source["x"] as? [[String: Any]] {
            result["x"] = registers.map { register -> [String: Any] in
                if let value = register["value"] as? NSNumber { return ["value": value] }
                return [:]
            }
        }
        return result
    }
}
