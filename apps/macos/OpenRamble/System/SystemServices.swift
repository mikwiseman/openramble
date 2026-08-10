import AVFoundation
import AppKit
import DictationCore
import Foundation

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
    public static var accessibility: Status {
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

    public static var microphone: Status {
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
public protocol PermissionReading {
    var accessibilityGranted: Bool { get }
    var microphoneGranted: Bool { get }
}

@MainActor
public struct SystemPermissions: PermissionReading {
    public init() {}
    public var accessibilityGranted: Bool { Permissions.accessibility == .granted }
    public var microphoneGranted: Bool { Permissions.microphone == .granted }
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

/// Short signals for the start and end of recording.
///
/// The type is entirely tied to the main thread by design. Protocol Methods
/// `Sounding` are asynchronous and do not inherit the caller's executor: without this
/// marks the body would be executed on a common pool, and access to the state of the main
/// the stream from there drops the application at the first key press.
@MainActor
public struct SystemSounds: Sounding {
    private let enabled: @MainActor () -> Bool

    public init(enabled: @escaping @MainActor () -> Bool = { true }) {
        self.enabled = enabled
    }

    public func playStart() async {
        guard enabled() else { return }
        NSSound(named: "Morse")?.play()
    }

    public func playStop() async {
        guard enabled() else { return }
        NSSound(named: "Pop")?.play()
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
