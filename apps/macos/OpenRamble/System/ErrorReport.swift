import Foundation

/// A local, explicitly saved bundle. This type has no networking or UI.
enum ErrorReport {
    static var crashDirectories: [URL] {
        let user = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
        let system = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
        return [user, user.appending(path: "Retired"), system, system.appending(path: "Retired")]
    }

    struct SystemInfo: Codable, Sendable {
        let appVersion: String
        let appBuild: String
        let macOS: String
        let architecture: String

        static var current: Self {
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            return Self(
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architecture
            )
        }
    }

    static func save(to destination: URL, journal: DictationLogFile,
                     directories: [URL] = crashDirectories,
                     info: SystemInfo = .current, now: Date = Date()) throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appending(path: "OpenRamble-report-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let folder = temporary.appending(path: "OpenRamble-Error-Report")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let snapshot = journal.snapshot(at: now)
        try snapshot.data.write(to: folder.appending(path: "events.jsonl"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: folder.appending(path: "system.json"))

        var skipped = 0
        var candidates: [(url: URL, date: Date)] = []
        let cutoff = now.addingTimeInterval(-7 * 86400)
        for directory in directories {
            guard manager.fileExists(atPath: directory.path) else { continue }
            do {
                for url in try manager.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]) {
                    guard url.lastPathComponent.hasPrefix("OpenRamble"), url.pathExtension == "ips" else { continue }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let date = values.contentModificationDate, date >= cutoff, date <= now else { continue }
                    guard let size = values.fileSize, size <= 5_000_000 else { skipped += 1; continue }
                    candidates.append((url, date))
                }
            } catch { skipped += 1 }
        }
        var included = 0
        var seen = Set<Data>()
        for candidate in candidates.sorted(by: { $0.date > $1.date }) {
            guard included < 5 else { break }
            do {
                let handle = try FileHandle(forReadingFrom: candidate.url)
                defer { try? handle.close() }
                let raw = try handle.read(upToCount: 5_000_001) ?? Data()
                guard raw.count <= 5_000_000,
                      let sanitized = try CrashReportSanitizer.sanitize(raw) else { skipped += 1; continue }
                guard seen.insert(sanitized).inserted else { continue }
                included += 1
                try sanitized.write(to: folder.appending(path: "crash-\(included).ips"))
            } catch { skipped += 1 }
        }
        let readme = """
        OpenRamble error report

        Saved locally at \(ISO8601DateFormatter().string(from: now)). Nothing was uploaded.
        Share this ZIP with the developer when asking for help.

        system.json: app version/build, macOS version/build, process architecture.
        events.jsonl: predefined technical events, timings and numeric error codes.
        Local journal: \(snapshot.enabled ? "enabled" : "disabled"), at most 7 days / 5 MB.
        Journal incomplete or unavailable: \(snapshot.incomplete ? "yes" : "no").
        Apple crash reports included: \(included) (up to 5 from the last 7 days).
        Unreadable, oversized or unsupported report sources skipped: \(skipped).
        \(included == 0 ? "No available Apple crash report was found. macOS may not have created or retained one; this does not mean that no crash occurred." : "Crash reports have been redacted. Addresses, image UUIDs and available stack frames are preserved; personal fields and free-form messages are omitted.")

        No audio, transcripts, clipboard, document contents, user paths, account or device identifiers are collected.
        No other applications' logs or system-wide log archive are included.
        Apple may leave stack frames empty or write a report after a delay.
        Missing frames cannot be reconstructed by this export.
        """
        try Data(readme.utf8).write(to: folder.appending(path: "README.txt"))
        let zip = temporary.appending(path: "report.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", folder.path, zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        // Atomic write also leaves an existing user-selected file intact if
        // generating or writing the replacement fails.
        guard let bytes = manager.contents(atPath: zip.path) else { throw CocoaError(.fileReadUnknown) }
        try bytes.write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
