import Foundation

/// The boundaries between pure dictation logic and the system.
///
/// Anything that requires AppKit, a microphone or other people's applications lives behind these
/// protocols. Thanks to them, the controller is tested with the usual `swift test`
/// in milliseconds and does not touch either the sound engine or other people's windows.

// MARK: - Audio capture

/// Record from a microphone to a file.
public protocol AudioCapturing: Sendable {
    /// Start recording. Returns the address of the file it goes to.
    ///
    /// The implementation must raise the engine synchronously: any delay here is
    /// cut off first word.
    func startRecording() async throws -> URL

    /// Wait for the first actually recorded frame of sound.
    ///
    /// `startRecording` is returned at engine startup, not at first
    /// heard sound: between these moments about a tenth passes
    /// seconds (0.13–0.14 s on M4 Pro, `docs/benchmarks.md`). Man,
    /// a person who begins to speak at the sound signal loses the first word in it -
    /// so the signal waits for this method.
    ///
    /// `true` - the frame has arrived. `false` - there is no more recording: the device is silent and
    /// the session is already closed. Promise “speak” where nothing is written,
    /// this is not possible, so there will be no signal for `false`.
    func waitForFirstFrame() async -> Bool

    /// Stop recording and append the file to disk.
    ///
    /// Returns the address of the finished file and the duration of the recorded file.
    func stopRecording() async throws -> (url: URL, duration: TimeInterval)

    /// Abort recording and delete file - the user canceled the dictation.
    func abortRecording() async

    /// How long the microphone was raised before the first frame. `nil` - not measured.
    func startupLatency() async -> Duration?
}

extension AudioCapturing {
    /// False tacklers in tests give up frames immediately - they have nothing to wait for.
    /// The default implementation is needed both for this and for adding a wait
    /// did not require touching each implementation at once.
    public func waitForFirstFrame() async -> Bool { true }

    /// `nil`, not zero: an edge that cannot measure heating has no
    /// the right to look instant.
    public func startupLatency() async -> Duration? { nil }
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case engineUnavailable(String)
    case unsupportedAudioFormat(String)
    case diskFull
    case writeFailed(String)
    case notRecording
}

// MARK: - Insert text

/// Where to insert and how.
public protocol TextInserting: Sendable {
    /// Insert text where the cursor was when dictation began.
    func insert(_ text: String, into target: TargetApplication?) async throws

    /// Press Return - if the user finished the phrase with the command “send”.
    func pressReturn() async throws

    /// The application that was active at the time the hotkey was pressed.
    ///
    /// Filmed at the beginning of the session, and not at the end: while recognition is in progress, focus
    /// could leave, and the text should go where it was dictated.
    func frontmostApplication() -> TargetApplication?

    /// Insert and tell when exactly the text went into someone else’s window.
    ///
    /// A separate method is needed because `insert` returns only via
    /// second of buffer protection: from the outside the moment of insertion cannot be caught, from the inside -
    /// trivial.
    func insertReportingMarks(
        _ text: String,
        into target: TargetApplication?
    ) async throws -> InsertionMarks
}

extension TextInserting {
    /// The default is a normal insert without marks. False inserters in
    /// tests do not measure anything and should not pretend to measure anything.
    public func insertReportingMarks(
        _ text: String,
        into target: TargetApplication?
    ) async throws -> InsertionMarks {
        try await insert(text, into: target)
        return InsertionMarks()
    }
}

/// Recipient application.
public struct TargetApplication: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public let localizedName: String?

    public init(bundleIdentifier: String?, processIdentifier: Int32, localizedName: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.localizedName = localizedName
    }
}

public enum TextInsertionError: Error, Sendable, Equatable {
    case accessibilityPermissionDenied
    /// Protected input is active - a password field or a terminal with keyboard protection.
    /// You cannot insert there, and this is not a failure, but a normal situation.
    case secureInputActive
    case clipboardWriteFailed
    /// Before Paste the clipboard could not be returned; no text inserted.
    case clipboardRestoreFailed
    /// Paste has already been sent, but the old clipboard could not be returned.
    case insertedButClipboardRestoreFailed
    /// The user did not release the modifiers, and the press would turn into someone else's combination.
    case modifiersStillHeld
    case targetUnavailable
    /// The active application has changed since the dictation target was captured.
    case targetChanged
}

// MARK: - Feedback

/// Dictation status indicator.
public protocol OverlayPresenting: Sendable {
    /// Show status. Called on every transition.
    func present(_ state: DictationState, elapsed: TimeInterval) async

    /// Remove the indicator.
    func dismiss() async

    /// Show a message that cannot be skipped - for example, that text
    /// failed to insert and it remained available in memory via Copy/Retry.
    func presentNotice(_ notice: DictationNotice) async
}

/// Message to the user.
public struct DictationNotice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case info
        case warning
        case failure
    }

    public let kind: Kind
    public let message: String
    /// Recognized text that could not be inserted. Process memory only.
    public let recoverableText: String?
    /// Local WAV saved after a technical failure.
    public let recoveryAudio: URL?

    public init(
        kind: Kind,
        message: String,
        recoverableText: String? = nil,
        recoveryAudio: URL? = nil
    ) {
        self.kind = kind
        self.message = message
        self.recoverableText = recoverableText
        self.recoveryAudio = recoveryAudio
    }
}

/// Sound confirmation of the beginning and end.
public protocol Sounding: Sendable {
    /// Played when the recording actually started.
    ///
    /// Exactly “when I went”, and not “when I clicked”: otherwise the user will start
    /// speak into a microphone that has not yet been launched.
    func playStart() async
    func playStop() async
}
