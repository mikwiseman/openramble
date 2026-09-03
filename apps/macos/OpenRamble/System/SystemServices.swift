import AVFoundation
import AppKit
import DictationCore
import Darwin
import Foundation

// MARK: - Active application snapshot

/// A lock-only snapshot of the application that most recently became active.
///
/// The hotkey path must never synchronously ask WindowServer/LaunchServices for
/// the frontmost application after microphone capture has started. If that IPC
/// wedges, MainActor cannot receive key-up or Escape while the microphone keeps
/// recording. NSWorkspace already publishes the exact application in its
/// activation notification, so production keeps that answer ahead of time and
/// key-down performs only a bounded memory read.
final class ActiveApplicationSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var observer: (any NSObjectProtocol)?
    private var target: TargetApplication?

    init(workspace: NSWorkspace = .shared) {
        center = workspace.notificationCenter
        observer = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: nil
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else { return }
            self?.store(application, onlyIfEmpty: false)
        }

        // Seed the cache away from MainActor. A slow initial LaunchServices
        // lookup may delay only the first available destination snapshot; it
        // can never hold the UI or a live microphone. A later activation
        // notification wins over this best-effort seed.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let application = NSWorkspace.shared.frontmostApplication else { return }
            self?.store(application, onlyIfEmpty: true)
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    func current() -> TargetApplication? {
        lock.withLock { target }
    }

    private func store(_ application: NSRunningApplication, onlyIfEmpty: Bool) {
        let snapshot = TargetApplication(
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            localizedName: application.localizedName
        )
        lock.withLock {
            if !onlyIfEmpty || target == nil { target = snapshot }
        }
    }
}

// MARK: - Permissions

/// Permissions, without which dictation does not work.
@MainActor
public enum Permissions {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
    }

    /// Universal access: needed for both hotkeys and text insertion.
    ///
    /// A separate “Input Monitoring” permission is not required - System Monitor
    /// events work under the same access.
    public nonisolated static var accessibility: Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Request access by showing the system window.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // Take the key as a string: the system constant is declared mutable
        // variable and fails Swift 6 thread safety check.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public nonisolated static var microphone: Status {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .denied
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    public static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}

/// Read permissions.
///
/// Behind the protocol - because the real answers depend on what the person
/// once allowed (in the test - to the test runner), and not from the logic being tested.
@MainActor
/// Sendable on purpose: the permission poll reads these off the main thread.
/// Both underlying APIs (`AXIsProcessTrusted`, `authorizationStatus`) are
/// thread-safe synchronous IPC — exactly the kind of call that must not sit
/// on the main thread once a second, where a slow daemon under system load
/// turns into a frozen interface.
public protocol PermissionReading: Sendable {
    nonisolated var accessibilityGranted: Bool { get }
    nonisolated var microphoneGranted: Bool { get }
}

public struct SystemPermissions: PermissionReading {
    public init() {}
    public nonisolated var accessibilityGranted: Bool { Permissions.accessibility == .granted }
    public nonisolated var microphoneGranted: Bool { Permissions.microphone == .granted }
}

/// The state of the live process, and not the position of the switch in Settings.
///
/// macOS may show an old TCC record enabled that does not match
/// designated requirement of the current binary. `AXIsProcessTrusted()` then
/// remains false, and this is the only authoritative answer for a running app.
public enum AccessibilityPermissionState: Sendable, Equatable {
    case denied
    case waitingForSettings
    case restartRequired
    case repairRequired
    case repairing
    case failed(String)
    case granted
}

@MainActor
public protocol AccessibilityManaging {
    @discardableResult
    func requestAccess() -> Bool
    func openSettings()
    func revealApplication()
    func resetAccess() async throws
    func relaunchApplication() async throws
}

public enum AccessibilityRecoveryError: LocalizedError, Equatable {
    case missingBundleIdentifier
    case resetFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            return "The app has no bundle identifier."
        case let .resetFailed(status, output):
            let suffix = output.isEmpty ? "" : " \(output)"
            return "tccutil exited with code \(status).\(suffix)"
        }
    }
}

/// Supported recovery path: official AX API, System Settings,
/// `tccutil` on an explicit user command and a full relaunch of the process.
/// The application does not read or modify TCC.db directly.
@MainActor
public struct SystemAccessibilityManager: AccessibilityManaging {
    public init() {}

    public func requestAccess() -> Bool {
        Permissions.requestAccessibility()
    }

    public func openSettings() {
        Permissions.openAccessibilitySettings()
    }

    public func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    public func resetAccess() async throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw AccessibilityRecoveryError.missingBundleIdentifier
        }

        // Waiting for completion - via terminationHandler, not waitUntilExit:
        // synchronous waiting on the main actor would freeze the interface for everything
        // running time tccutil.
        let result: (status: Int32, message: String) = try await withCheckedThrowingContinuation {
            continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleIdentifier]
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (finished.terminationStatus, message))
            }
            do {
                try process.run()
            } catch {
                // The process did not start - terminationHandler will not work.
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard result.status == 0 else {
            throw AccessibilityRecoveryError.resetFailed(result.status, result.message)
        }
    }

    public func relaunchApplication() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        )
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Sounds

private final class SoundSessionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: DictationSessionID?

    func advance(to session: DictationSessionID) {
        lock.lock()
        if latest.map({ session >= $0 }) ?? true { latest = session }
        lock.unlock()
    }

    func accepts(_ session: DictationSessionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latest == session
    }
}

/// The single "look at the panel" signal.
///
/// The type is entirely tied to the main thread by design. Protocol Methods
/// `Sounding` are asynchronous and do not inherit the caller's executor: without this
/// marks the body would be executed on a common pool, and access to the state of the main
/// the stream from there drops the application at the first key press.
@MainActor
public struct SystemSounds: Sounding {
    private let enabled: @MainActor () -> Bool
    private let sessionFence = SoundSessionFence()

    public init(enabled: @escaping @MainActor () -> Bool = { true }) {
        self.enabled = enabled
    }

    public func playAttention() async {
        guard enabled() else { return }
        // Submarine: low and calm. What happened is recoverable — the text is
        // still offered in the menu — so the sound must not read as an alarm.
        NSSound(named: "Submarine")?.play()
    }

    nonisolated public func advance(to session: DictationSessionID) {
        sessionFence.advance(to: session)
    }

    public func playAttention(session: DictationSessionID) async {
        guard sessionFence.accepts(session) else { return }
        await playAttention()
    }
}

// MARK: - Application paths

/// Where the application stores its files.
///
/// The root is set externally: the test must run in a temporary folder, not in
/// present Application Support of the person who is dictating at this moment.
public struct AppPaths: Sendable {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The usual location is Application Support for the current user.
    ///
    /// The directory itself is not created here: it will be created by the first `support()` together
    /// with your own folder. File system failure should be visible where we
    /// going to write, not when calculating the place name.
    public static func standard() -> AppPaths {
        #if DEBUG
        // Live verification must be able to point a debug build at a scratch
        // root. A HOME override does NOT do it: this FileManager API resolves
        // the real user record and ignores the environment, and a dev
        // instance sharing Takes/ with the production app once swallowed a
        // live recording. Debug builds only; release has no such path.
        if let override = ProcessInfo.processInfo.environment["OPENRAMBLE_SUPPORT_ROOT"],
           !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        #endif
        // For Application Support in the user's domain, the list is always exactly
        // one element. There is no backup route for this case intentionally:
        // inserting something else here would mean writing data in the wrong place.
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            preconditionFailure("The system did not report the Application Support location")
        }
        return AppPaths(root: base)
    }

    /// Application data root.
    public func support() throws -> URL {
        let directory = root.appending(path: "OpenRamble", directoryHint: .isDirectory)
        let fileManager = FileManager.default

        // Builds released before the product rename used a different folder name.
        // Move the complete directory once so downloaded models and recovered audio
        // remain available after the update. The split spelling keeps the retired
        // brand out of current product metadata while documenting the migration.
        if !fileManager.fileExists(atPath: directory.path) {
            let legacyName = ["Wai", "Dictation"].joined()
            let legacy = root.appending(path: legacyName, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: legacy.path) {
                try fileManager.moveItem(at: legacy, to: directory)
            }
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func models() throws -> URL {
        try support().appending(path: "Models", directoryHint: .isDirectory)
    }

    /// Where notes are written during dictation.
    ///
    /// The file lives exactly until the end of recognition and is immediately deleted - voice
    /// The user should not remain on the disk.
    public func takes() throws -> URL {
        let directory = try support().appending(path: "Takes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(directory)
        return directory
    }

    /// WAVs saved only after a technical error or process kill.
    public func audioRecovery() throws -> URL {
        let directory = try support().appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(directory)
        return directory
    }

    /// Recordings the person made on purpose, kept until they delete them.
    ///
    /// Deliberately *not* excluded from backup, unlike the folders above.
    /// Those hold transient voice — a take exists for the seconds between
    /// speaking and inserting — and backing them up is pure downside. A
    /// recording is a document, the only copy of an hour of someone's day,
    /// and a disk failure silently destroying it is the worse outcome. The
    /// dictation history beside it is not excluded either.
    public func recordings() throws -> URL {
        let directory = try support().appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }


    /// Recordings and recovered texts are not something worth storing in backup
    /// copies: this is the content of the user's speech.
    ///
    /// The error is not swallowed. The dictation that silently went into backup is exactly what
    /// what a person does not expect from a private product, and he would like to know about it
    /// out of nowhere.
    private static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}

// MARK: - Retired MCP staging cleanup

/// Removes voice files left by the retired 0.6.x MCP helper after an app or
/// agent crash. The old helper staged only `audio-<UUID>.<short-extension>`
/// inside the app's private Darwin temporary namespace. Keeping this small,
/// exact parser in the upgrade path avoids retaining those recordings forever
/// without bringing the public MCP server back into the product.
enum LegacyAgentStagingCleanup {
    private static let productionNamespace = "is.waiwai.dictation"
    private static let developmentNamespace = "is.waiwai.dictation.dev"

    static func removeAbandonedAudio(
        bundleIdentifier: String,
        temporaryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let namespace = bundleIdentifier == developmentNamespace
            ? developmentNamespace
            : productionNamespace
        guard let temporaryDirectory = temporaryDirectory ?? darwinUserTemporaryDirectory()
        else { return }

        let runtime = temporaryDirectory.appending(
            path: namespace,
            directoryHint: .isDirectory
        )
        let incoming = runtime.appending(path: "incoming", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: incoming.path) {
            for name in try fileManager.contentsOfDirectory(atPath: incoming.path)
            where isRetiredAudioName(name) {
                // `removeItem` removes a symlink itself rather than following it.
                // The exact basename parser also prevents escaping `incoming/`.
                try fileManager.removeItem(at: incoming.appending(path: name))
            }

            if (try? fileManager.contentsOfDirectory(atPath: incoming.path).isEmpty) == true {
                try? fileManager.removeItem(at: incoming)
            }
        }
        let retiredSocket = runtime.appending(path: "agent-v1.sock")
        if fileManager.fileExists(atPath: retiredSocket.path) {
            try? fileManager.removeItem(at: retiredSocket)
        }
        if (try? fileManager.contentsOfDirectory(atPath: runtime.path).isEmpty) == true {
            try? fileManager.removeItem(at: runtime)
        }
    }

    private static func darwinUserTemporaryDirectory() -> URL? {
        let requiredBytes = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard requiredBytes > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: requiredBytes)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, requiredBytes) > 0 else {
            return nil
        }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return URL(fileURLWithPath: String(cString: baseAddress), isDirectory: true)
        }
    }

    private static func isRetiredAudioName(_ name: String) -> Bool {
        guard name.utf8.count <= 64, !name.contains("/"), !name.contains(":"),
              !name.utf8.contains(0)
        else { return false }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].hasPrefix("audio-"),
              UUID(uuidString: String(parts[0].dropFirst("audio-".count))) != nil,
              !parts[1].isEmpty,
              parts[1].utf8.count <= 10
        else { return false }
        return parts[1].unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }
    }
}
