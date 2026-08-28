import Foundation

private final class DictationSessionIDAllocator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 1

    func allocate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        precondition(nextGeneration < UInt64.max, "dictation session generation exhausted")
        defer { nextGeneration += 1 }
        return nextGeneration
    }
}

private let dictationSessionIDAllocator = DictationSessionIDAllocator()

/// Process-unique identity for one dictation.
///
/// It carries both an opaque UUID and a process-wide monotonic generation.
/// UUID equality scopes capture ownership even if a controller is recreated;
/// generation orders delayed UI commands across controller lifetimes.
public struct DictationSessionID: Sendable, Hashable, Comparable {
    public let rawValue: UUID
    fileprivate let generation: UInt64

    public init() {
        rawValue = UUID()
        generation = dictationSessionIDAllocator.allocate()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.generation < rhs.generation
    }
}

/// Durable intent for every file that may be created by one dictation.
///
/// Task cancellation and controller identity are deliberately not used as the
/// source of truth: both disappear when the UI returns to idle while a storage
/// syscall may finish much later. Capture and recovery register paths before
/// starting I/O; an accepted Escape therefore also deletes paths registered by
/// a late materializer, while a technical failure explicitly keeps them.
public final class RecordingDisposition: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case active
        case deleteRequested
        case keepInBackground
        case published
    }

    private let lock = NSLock()
    private var current: State = .active
    private var paths: [URL] = []
    private var pathSet: Set<URL> = []
    private let dispose: @Sendable ([URL]) -> Void

    public init() {
        dispose = { RecordingFileDisposer.shared.submit($0) }
    }

    /// Deterministic fault-injection seam; production uses the public init.
    init(dispose: @escaping @Sendable ([URL]) -> Void) {
        self.dispose = dispose
    }

    public var state: State { lock.withLock { current } }

    /// Register before the corresponding create/open/move begins.
    public func register(_ urls: [URL]) {
        let lateDelete: [URL] = lock.withLock {
            for url in urls where pathSet.insert(url).inserted {
                paths.append(url)
            }
            // Re-registration is intentional: a creator registers before I/O,
            // Escape may attempt deletion while the path does not exist, and
            // the cancellation-deaf create may then return. Its post-create
            // registration must schedule deletion again.
            guard current == .deleteRequested else { return [] }
            var seen: Set<URL> = []
            return urls.filter { seen.insert($0).inserted }
        }
        if !lateDelete.isEmpty { dispose(lateDelete) }
    }

    /// User cancellation wins over active/background recovery, but never over
    /// an already published Retry item (that item has its own explicit Delete).
    @discardableResult
    public func requestDelete() -> Bool {
        let result: (Bool, [URL]) = lock.withLock {
            guard current != .published else { return (false, []) }
            current = .deleteRequested
            return (true, paths)
        }
        if !result.1.isEmpty { dispose(result.1) }
        return result.0
    }

    /// A technical failure transfers ownership from the foreground UI to the
    /// recovery transaction. It is idempotent and cannot undo an Escape.
    @discardableResult
    public func keepInBackground() -> Bool {
        lock.withLock {
            switch current {
            case .active:
                current = .keepInBackground
                return true
            case .keepInBackground, .published:
                return true
            case .deleteRequested:
                return false
            }
        }
    }

    /// Commit the recovery item as user-visible. Once published, ordinary
    /// session cleanup may no longer reinterpret it as a cancellation.
    @discardableResult
    public func markPublished() -> Bool {
        lock.withLock {
            guard current != .deleteRequested else { return false }
            current = .published
            return true
        }
    }
}

/// The boundaries between pure dictation logic and the system.
///
/// Anything that requires AppKit, a microphone or other people's applications lives behind these
/// protocols. Thanks to them, the controller is tested with the usual `swift test`
/// in milliseconds and does not touch either the sound engine or other people's windows.

// MARK: - Audio capture

/// One stopped recording, frozen at the microphone boundary.
///
/// The recognizer-ready PCM and both file milestones belong to this exact
/// recording. Keeping them together prevents a late completion from one
/// session from taking the buffer or closing the writer of the next one.
public struct CapturedRecording: Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let samples: [Float]?
    /// How much of `samples` was already recognized while the take was running.
    ///
    /// Everything before this offset has left in a segment and has a transcript
    /// already; everything after it is the tail nobody has looked at yet. Zero
    /// means the take was not segmented and must be recognized whole, which is
    /// what every capture that does not segment reports.
    public let consumedSampleCount: Int
    /// Capture-start latency frozen with this exact recording.
    ///
    /// This is diagnostic data only. Keeping it in the artifact prevents a
    /// post-ASR actor hop from delaying insertion or accidentally reading the
    /// next session's metric.
    public let startupLatency: Duration?
    public let disposition: RecordingDisposition

    private let readableTask: Task<URL, Error>
    private let durableTask: Task<URL, Error>
    private let materializeRecovery: (@Sendable () async throws -> URL)?

    /// A capture whose file is already closed and durable. This is the
    /// compatibility path for file-only captures and test doubles.
    public init(
        url: URL,
        duration: TimeInterval,
        samples: [Float]? = nil,
        startupLatency: Duration? = nil,
        disposition: RecordingDisposition = RecordingDisposition(),
        consumedSampleCount: Int = 0
    ) {
        disposition.register([url])
        let ready = Task<URL, Error> { url }
        self.init(
            url: url,
            duration: duration,
            samples: samples,
            startupLatency: startupLatency,
            disposition: disposition,
            readableTask: ready,
            durableTask: ready,
            materializeRecovery: nil,
            consumedSampleCount: consumedSampleCount
        )
    }

    /// A capture that can expose PCM before its recovery WAV reaches disk.
    ///
    /// `readableTask` completes after the payload and final WAV header can be
    /// opened by a decoder. `durableTask` additionally fsyncs and closes the
    /// file; it must never gate the ordinary in-memory dictation path.
    public init(
        url: URL,
        duration: TimeInterval,
        samples: [Float]?,
        startupLatency: Duration? = nil,
        disposition: RecordingDisposition = RecordingDisposition(),
        readableTask: Task<URL, Error>,
        durableTask: Task<URL, Error>,
        materializeRecovery: (@Sendable () async throws -> URL)? = nil,
        consumedSampleCount: Int = 0
    ) {
        self.url = url
        self.duration = duration
        self.samples = samples
        self.consumedSampleCount = consumedSampleCount
        self.startupLatency = startupLatency
        self.disposition = disposition
        disposition.register([url])
        self.readableTask = readableTask
        self.durableTask = durableTask
        self.materializeRecovery = materializeRecovery
    }

    public func readableURL() async throws -> URL {
        try await readableTask.value
    }

    public func durableURL() async throws -> URL {
        try await durableTask.value
    }

    /// Rebuild a complete recovery WAV from the bounded in-memory PCM.
    ///
    /// This is lazy: successful dictations never write a second audio file.
    /// The capture implementation single-flights the work and bounds stuck
    /// storage globally, so retries cannot create an FD/task leak.
    public func materializedRecoveryURL() async throws -> URL? {
        guard let materializeRecovery else { return nil }
        return try await materializeRecovery()
    }
}

/// Record from a microphone to a file.
public protocol AudioCapturing: Sendable {
    /// Ask for finished pieces of the take as it runs, so the engine can start
    /// before the person stops talking.
    ///
    /// Optional, and its default is the behaviour every existing capture
    /// already has: no sink, no segments, the take recognized whole at the end.
    /// A capture that cannot segment does not have to pretend it can.
    func setSegmentSink(_ sink: (@Sendable ([Float]) -> Void)?) async

    /// Start recording. Returns the address of the file it goes to.
    ///
    /// The implementation must begin device startup promptly without blocking
    /// the controller's executor. Any delay before startup can clip the first
    /// word; a native startup that stalls must remain independently containable.
    func startRecording() async throws -> URL

    /// Start a recording owned by the controller session.
    ///
    /// Unlike a URL, the identity exists before the asynchronous device start
    /// begins, so cancellation during `.preparing` can never become an
    /// unscoped abort of a later recording.
    func startRecording(session: DictationSessionID) async throws -> URL

    /// Start with the session's file disposition already installed. Production
    /// capture registers raw/partial/final paths on it before any storage I/O.
    func startRecording(
        session: DictationSessionID,
        disposition: RecordingDisposition
    ) async throws -> URL

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

    /// Stop input and atomically move this recording's recognizer-ready PCM
    /// and file finalization milestones to the caller.
    ///
    /// Production capture overrides this so recognition can begin before WAV
    /// fsync. File-only implementations inherit the closed-file adapter below.
    func freezeRecording() async throws -> CapturedRecording

    /// Stop only the recording that returned `expectedURL`.
    ///
    /// A stale controller continuation can resume after Escape and after a new
    /// microphone session has started. Production capture must reject that old
    /// request rather than freezing the new session.
    func freezeRecording(expectedURL: URL) async throws -> CapturedRecording

    /// Session- and URL-scoped stop used by the live controller.
    func freezeRecording(
        session: DictationSessionID,
        expectedURL: URL
    ) async throws -> CapturedRecording

    /// Move the just-finished 16 kHz mono Float32 recording out of capture memory.
    ///
    /// A capture that can provide this lets recognition begin from the exact PCM
    /// that was written instead of opening the finished Int16 WAV and converting
    /// the whole recording back to Float32. The WAV remains the durable recovery
    /// copy. Returning `nil` keeps file-only captures and test doubles compatible.
    func takeBufferedSamples() async -> [Float]?

    /// Abort recording and delete file - the user canceled the dictation.
    func abortRecording() async

    /// Abort only the recording that returned `expectedURL` from
    /// `startRecording()`.
    ///
    /// A timed-out finalizer may finish after the next session has already
    /// begun. Session-aware capture implementations use this identity to make
    /// a stale cancellation harmless instead of stopping the new microphone.
    func abortRecording(expectedURL: URL?) async

    /// Abort only work owned by this controller session. `expectedURL == nil`
    /// means that this session has not returned its path yet; it is never a
    /// wildcard for the currently active microphone.
    func abortRecording(session: DictationSessionID, expectedURL: URL?) async

    /// Fence microphone/device work for a failed or timed-out session while
    /// preserving any raw take for technical recovery. Unlike `abort`, this
    /// operation must never unlink `expectedURL` when no active context exists.
    func containRecording(session: DictationSessionID, expectedURL: URL?) async

    /// How long the microphone was raised before the first frame. `nil` - not measured.
    func startupLatency() async -> Duration?
}

extension AudioCapturing {
    /// Not segmenting is a complete implementation of this protocol.
    ///
    /// Every test double and every capture that predates streaming gets this,
    /// and gets exactly the behaviour it had: the controller receives no
    /// segments and recognizes the take whole.
    public func setSegmentSink(_ sink: (@Sendable ([Float]) -> Void)?) async {}

    /// Compatibility for capture doubles whose calls cannot overlap sessions.
    public func startRecording(session: DictationSessionID) async throws -> URL {
        try await startRecording()
    }

    public func startRecording(
        session: DictationSessionID,
        disposition: RecordingDisposition
    ) async throws -> URL {
        let url = try await startRecording(session: session)
        disposition.register([url])
        return url
    }

    /// False tacklers in tests give up frames immediately - they have nothing to wait for.
    /// The default implementation is needed both for this and for adding a wait
    /// did not require touching each implementation at once.
    public func waitForFirstFrame() async -> Bool { true }

    /// `nil`, not zero: an edge that cannot measure heating has no
    /// the right to look instant.
    public func startupLatency() async -> Duration? { nil }

    /// File-only captures remain valid; the controller falls back to the WAV.
    public func takeBufferedSamples() async -> [Float]? { nil }

    /// Compatibility for captures without per-session cancellation. The
    /// production microphone overrides this method.
    public func abortRecording(expectedURL: URL?) async {
        await abortRecording()
    }

    /// Compatibility for captures that only know how to return a closed WAV.
    public func freezeRecording() async throws -> CapturedRecording {
        let recording = try await stopRecording()
        return CapturedRecording(
            url: recording.url,
            duration: recording.duration,
            samples: await takeBufferedSamples(),
            startupLatency: await startupLatency()
        )
    }

    /// Compatibility for capture doubles that cannot overlap sessions. The
    /// production microphone validates the URL before detaching its context.
    public func freezeRecording(expectedURL: URL) async throws -> CapturedRecording {
        try await freezeRecording()
    }

    /// Compatibility for capture doubles whose calls cannot overlap sessions.
    public func freezeRecording(
        session: DictationSessionID,
        expectedURL: URL
    ) async throws -> CapturedRecording {
        try await freezeRecording(expectedURL: expectedURL)
    }

    /// Compatibility for capture doubles whose calls cannot overlap sessions.
    public func abortRecording(session: DictationSessionID, expectedURL: URL?) async {
        await abortRecording(expectedURL: expectedURL)
    }

    /// Compatibility captures stop through their ordinary non-destructive
    /// freeze. Production overrides this with a generation-fenced fast path.
    public func containRecording(session: DictationSessionID, expectedURL: URL?) async {
        if let expectedURL {
            _ = try? await freezeRecording(session: session, expectedURL: expectedURL)
        } else {
            _ = try? await freezeRecording()
        }
    }
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

    /// Send Return to the same application captured for this dictation. The
    /// default keeps old/test inserters source-compatible; production targets
    /// the process so an actor-turn focus change cannot redirect the command.
    func pressReturn(into target: TargetApplication?) async throws

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
    public func pressReturn(into target: TargetApplication?) async throws {
        try await pressReturn()
    }

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
    /// A prior system event is still inside a cancellation-deaf paste edge.
    /// Starting another clipboard transaction could make that late event paste
    /// the new dictation or the user's restored clipboard into the old target.
    case insertionInProgress
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

    /// Session-scoped variants reject stale UI commands after a later
    /// dictation has begun. Implementations with real mutable UI should
    /// override these; simple test doubles may use the compatibility defaults.
    func present(
        _ state: DictationState,
        elapsed: TimeInterval,
        session: DictationSessionID
    ) async
    func dismiss(session: DictationSessionID) async
    func presentNotice(_ notice: DictationNotice, session: DictationSessionID) async

    /// Publish the newest command before it is queued. Real UI uses this
    /// synchronous fence to reject an older in-flight command at its eventual
    /// mutation point, including commands from a previous controller instance.
    func advance(to session: DictationSessionID, revision: UInt64)
    func present(
        _ state: DictationState,
        elapsed: TimeInterval,
        session: DictationSessionID,
        revision: UInt64
    ) async
    func dismiss(session: DictationSessionID, revision: UInt64) async
    func presentNotice(
        _ notice: DictationNotice,
        session: DictationSessionID,
        revision: UInt64
    ) async
}

extension OverlayPresenting {
    public func present(
        _ state: DictationState,
        elapsed: TimeInterval,
        session: DictationSessionID
    ) async {
        await present(state, elapsed: elapsed)
    }

    public func dismiss(session: DictationSessionID) async {
        await dismiss()
    }

    public func presentNotice(_ notice: DictationNotice, session: DictationSessionID) async {
        await presentNotice(notice)
    }

    public func advance(to session: DictationSessionID, revision: UInt64) {}

    public func present(
        _ state: DictationState,
        elapsed: TimeInterval,
        session: DictationSessionID,
        revision: UInt64
    ) async {
        await present(state, elapsed: elapsed, session: session)
    }

    public func dismiss(session: DictationSessionID, revision: UInt64) async {
        await dismiss(session: session)
    }

    public func presentNotice(
        _ notice: DictationNotice,
        session: DictationSessionID,
        revision: UInt64
    ) async {
        await presentNotice(notice, session: session)
    }
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
    /// Whether the words failed to land where the person expected them.
    ///
    /// This — not the kind — decides the attention sound. "The text was
    /// inserted, but pressing Return failed" is a warning whose words DID
    /// land; "nothing was recognized" is mere info whose words did NOT.
    /// A person watching their editor needs the ear only for the second.
    public let wordsDidNotLand: Bool

    public init(
        kind: Kind,
        message: String,
        recoverableText: String? = nil,
        recoveryAudio: URL? = nil,
        wordsDidNotLand: Bool? = nil
    ) {
        self.kind = kind
        self.message = message
        self.recoverableText = recoverableText
        self.recoveryAudio = recoveryAudio
        // Failures lose the words by definition; anything else says so
        // explicitly at the site that knows.
        self.wordsDidNotLand = wordsDidNotLand ?? (kind == .failure)
    }
}

/// The one sound the product has: "look at the panel".
///
/// Not a start chime and not a stop chime. A working dictation already shows
/// itself — the panel while recording, the text at the cursor when it lands —
/// and a sound on every session teaches the ear to ignore sounds. This one
/// plays only when the app has something to say: the words did not reach the
/// field, nothing was recognized, something failed. Silence means it worked.
public protocol Sounding: Sendable {
    func playAttention() async
    /// Fence delayed sound work to the newest dictation generation.
    func advance(to session: DictationSessionID)
    func playAttention(session: DictationSessionID) async
}

extension Sounding {
    public func advance(to session: DictationSessionID) {}

    public func playAttention(session: DictationSessionID) async {
        await playAttention()
    }
}
