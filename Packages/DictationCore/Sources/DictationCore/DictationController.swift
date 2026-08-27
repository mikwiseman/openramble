import Foundation

/// What to do with recognized text if it was not possible to insert it.
public struct RecoveredDictation: Sendable, Equatable {
    public let text: String
}

private enum DictationOverlayCommand: Sendable {
    case present(DictationState, TimeInterval, DictationSessionID, UInt64)
    case notice(DictationNotice, DictationSessionID, UInt64)
    case dismiss(DictationSessionID, UInt64)

    var session: DictationSessionID {
        switch self {
        case let .present(_, _, session, _), let .notice(_, session, _), let .dismiss(session, _):
            return session
        }
    }

    var revision: UInt64 {
        switch self {
        case let .present(_, _, _, revision), let .notice(_, _, revision), let .dismiss(_, revision):
            return revision
        }
    }

    var isNotice: Bool {
        if case .notice = self { return true }
        return false
    }
}

/// One in-flight UI call plus at most one notice and one latest state command.
///
/// If the window server wedges, dictation keeps moving and repeated sessions
/// cannot accumulate an unbounded number of tasks. A newer session replaces
/// every queued command from an older one. Within a session a notice is kept
/// ahead of the later dismiss so failures remain visible.
private final class DictationOverlayDispatcher: @unchecked Sendable {
    private let overlay: any OverlayPresenting
    private let lock = NSLock()
    private var latestSession: DictationSessionID?
    private var pendingNotice: DictationOverlayCommand?
    private var pendingState: DictationOverlayCommand?
    private var isRunning = false

    init(overlay: any OverlayPresenting) {
        self.overlay = overlay
    }

    func submit(_ command: DictationOverlayCommand) {
        var shouldLaunch = false
        lock.lock()
        if let latestSession, command.session < latestSession {
            lock.unlock()
            return
        }
        if latestSession != command.session {
            latestSession = command.session
            pendingNotice = nil
            pendingState = nil
        }
        if command.isNotice {
            pendingNotice = command
        } else {
            pendingState = command
        }
        if !isRunning {
            isRunning = true
            shouldLaunch = true
        }
        lock.unlock()

        if shouldLaunch {
            Task { await self.drain() }
        }
    }

    private func takeNext() -> DictationOverlayCommand? {
        lock.lock()
        defer { lock.unlock() }

        let next: DictationOverlayCommand?
        switch (pendingNotice, pendingState) {
        case let (notice?, state?):
            if notice.revision <= state.revision {
                pendingNotice = nil
                next = notice
            } else {
                pendingState = nil
                next = state
            }
        case let (notice?, nil):
            pendingNotice = nil
            next = notice
        case let (nil, state?):
            pendingState = nil
            next = state
        case (nil, nil):
            isRunning = false
            next = nil
        }
        return next
    }

    private func drain() async {
        while let command = takeNext() {
            // This protocol edge is intentionally off the controller actor. A
            // broken UI fence can retain this one bounded feedback task, never
            // microphone start/stop or the session state machine.
            overlay.advance(to: command.session, revision: command.revision)
            switch command {
            case let .present(state, elapsed, session, revision):
                await overlay.present(
                    state,
                    elapsed: elapsed,
                    session: session,
                    revision: revision
                )
            case let .notice(notice, session, revision):
                await overlay.presentNotice(notice, session: session, revision: revision)
            case let .dismiss(session, revision):
                await overlay.dismiss(session: session, revision: revision)
            }
        }
    }
}

/// Sound feedback is also decoration: one stuck backend may retain one task,
/// never the controller and never one task per later failure.
private final class DictationSoundDispatcher: @unchecked Sendable {
    private let sounds: any Sounding
    private let lock = NSLock()
    private var latestSession: DictationSessionID?
    private var pendingSession: DictationSessionID?
    private var isRunning = false

    init(sounds: any Sounding) {
        self.sounds = sounds
    }

    func advance(to session: DictationSessionID) {
        lock.lock()
        if latestSession.map({ session >= $0 }) ?? true {
            latestSession = session
            if pendingSession.map({ $0 < session }) == true { pendingSession = nil }
        }
        lock.unlock()
    }

    func submit(session: DictationSessionID) {
        advance(to: session)
        var shouldLaunch = false
        lock.lock()
        guard latestSession == session else {
            lock.unlock()
            return
        }
        pendingSession = session
        if !isRunning {
            isRunning = true
            shouldLaunch = true
        }
        lock.unlock()
        if shouldLaunch { Task { await self.drain() } }
    }

    private func takeNext() -> DictationSessionID? {
        lock.lock()
        defer { lock.unlock() }
        guard let pendingSession else {
            isRunning = false
            return nil
        }
        self.pendingSession = nil
        return pendingSession
    }

    private func drain() async {
        while let session = takeNext() {
            sounds.advance(to: session)
            await sounds.playAttention(session: session)
        }
    }
}

private enum CaptureStartOutcome: Sendable {
    case started(URL)
    case failed(String)
}

/// Preparation exceeded the foreground stop-to-result budget. This is not an
/// inference stall: a separately owned model load may still be healthy and
/// must not be killed just as it is about to become ready.
private struct DictationPreparationTimeout: Error, Sendable {}

/// Dictation core.
///
/// Holds the state of the session and carries it through from keypress to text insertion.
/// Knows nothing about AppKit, nor about the microphone, nor about the model - all this
/// comes from outside via protocols, so it is tested here.
///
/// Invariants, without which the product breaks on the very first users,
/// collected in separate checks along the code: each of them came from
/// a real bug in the previous product.
@MainActor
public final class DictationController {
    // MARK: - Observable state

    public private(set) var state: DictationState = .idle {
        didSet {
            // We check equality intentionally: the interface is subscribed to changes,
            // and permissions are polled once per second. Without this check the window
            // settings would be redrawn every second.
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    public private(set) var pendingRecovery: RecoveredDictation?

    public var onStateChange: (@MainActor (DictationState) -> Void)?
    public var onNotice: (@MainActor (DictationNotice) -> Void)?
    /// Successful insertion is the only proof that the first sample
    /// actually passed and was not manually typed into the TextEditor.
    /// Successful insertion - with text that actually went into the application.
    /// The “correct the last dictation” window needs the text; it doesn't get to disk.
    public var onTextInserted: (@MainActor (String) -> Void)?
    /// The origin of the dictation just inserted: what the text was and what it has become.
    ///
    /// A separate callback, not an extension `onTextInserted`: that one is pulled by four
    /// a set of tests that know nothing about the origin, and change it
    /// the signature would have to be in everyone. The additive optional callback does not see them.
    public var onDictationCompleted: (@MainActor (PipelineProvenance) -> Void)?
    /// How long did it take “let go → text in place.” For successful inserts only:
    /// the unsuccessful one does not have an honest number.
    public var onSpeed: (@MainActor (DictationSpeedReport) -> Void)?
    /// Tells whether recording is going on without holding: this determines how
    /// interpret the next keystroke.
    public var onHandsFreeChange: (@MainActor (Bool) -> Void)?
    /// Recognition exceeded its deadline — the engine is presumed wedged on a
    /// dead system service. The owner should recycle it so the next dictation
    /// runs on a fresh session instead of the same stuck one.
    public var onTranscriptionStall: (@MainActor () -> Void)?
    /// A take that produced text, with the audio still on disk.
    ///
    /// Called after insertion is attempted and before the recording is
    /// deleted, so an owner that keeps a history gets both halves of the take
    /// while both still exist. Whether the words actually landed is not the
    /// question here — a person who watched an insertion fail wants that
    /// transcript more than anyone, not less.
    public var onTakeFinished: (@MainActor (String, URL) -> Void)?
    /// The take is finished and the model is not resident yet, so the words are
    /// waiting for a load rather than for recognition.
    ///
    /// The panel is the only feedback channel during dictation, and until now
    /// it said "Transcribing…" through the whole wait — up to the preparation
    /// deadline. Calling a wait work is a small lie that becomes a large one on
    /// a short take, which has no speech for the load to hide under: the person
    /// watches a spinner claim to transcribe half a second of audio for fifteen
    /// seconds. `true` opens the wait, `false` closes it on every exit,
    /// including a throw.
    public var onEnginePreparationWait: (@MainActor (Bool) -> Void)?

    /// Whether recording occurs without holding down a key.
    public private(set) var isHandsFreeActive = false {
        didSet {
            guard oldValue != isHandsFreeActive else { return }
            onHandsFreeChange?(isHandsFreeActive)
        }
    }

    // MARK: - Dependencies

    private let capture: any AudioCapturing
    private let transcribe: @Sendable (URL) async throws -> ASRResult
    /// Fast path for captures that already own recognizer-ready PCM. The file
    /// closure remains the compatibility and recovery path.
    private let transcribeSamples: (@Sendable ([Float]) async throws -> ASRResult)?
    /// Recognizes the take in pieces while it is still being spoken.
    ///
    /// Present only when there is a sample-path recognizer to give it to and a
    /// capture willing to segment. Absent means the old behaviour exactly: one
    /// decode of the whole take once the key comes up.
    private var streamedSegments: StreamedSegmentRecognizer?
    /// Sample rate every part of this app agrees on. Named rather than spelled
    /// out at the three places below that need it.
    private static let sampleRate = 16_000
    /// Below this a piece of audio is not handed to the engine on its own.
    ///
    /// Measured against the shipping model: under about two seconds its output
    /// is not merely worse but non-monotonic — the same start offset returned
    /// text at 0.8 s, nothing at 1.0 s, text again at 1.2 s. A tail shorter than
    /// this is recognized together with the segment before it instead.
    private static let minimumTailSamples = 2 * sampleRate
    private let inserter: any TextInserting
    private let overlay: any OverlayPresenting
    private let sounds: any Sounding
    private let overlayDispatcher: DictationOverlayDispatcher
    private let soundDispatcher: DictationSoundDispatcher
    private let recordingRecovery: any RecordingRecoveryStoring
    private let pipeline: () -> any TextProcessing
    /// Session hours. A separate dependence for exactly the same reason as
    /// microphone.
    private let now: @Sendable () -> Date
    /// The monotonous clock is separate from the wall clock, and this is not duplication.
    ///
    /// `now` supplies wall time where a human-readable moment is needed.
    /// Wall clock speeds are not suitable at all: sleep, daylight saving time
    /// or NTF input in the middle of dictation would give “−400 ms”, that is, just
    /// lies. `MicrophoneCapture` and `TextInserter` already live on
    /// `ContinuousClock`, so all marks are comparable to each other.
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    /// How long recognition may run for a recording of a given duration.
    /// Injectable so tests do not wait twenty real seconds for a stall.
    private let transcriptionDeadline: @Sendable (TimeInterval) -> Duration
    /// Bring the engine into memory before recognition, when the owner
    /// manages residency. Separate from `transcribe` so a cold reload gets
    /// its own generous budget instead of eating the recognition deadline:
    /// a load that overlaps the person's speech must not count against the
    /// transcription of a two-second utterance.
    private let prepareForTranscription: (@Sendable () async throws -> Void)?
    /// The reload budget. Covers a cache-purged model compile; a breach means
    /// the engine is wedged and flows into the same stall recovery.
    private let prepareDeadline: Duration
    /// How long a stop-time model wait may stay silent before the panel says
    /// so. Injectable so suites can prove both the announcement and the
    /// silence without sleeping a production-scale interval.
    private let enginePreparationNoticeDelay: Duration
    /// Capture stop owns only the audio-engine handoff and PCM freeze. Disk
    /// drain and fsync are separate milestones and do not consume this budget.
    private let captureFreezeDeadline: Duration
    /// Rare file-only recordings wait for a readable WAV, never for fsync.
    private let recordingReadableDeadline: Duration
    /// Moving a failed take into the support folder is also storage I/O and
    /// therefore cannot own the UI indefinitely.
    private let recordingPreserveDeadline: Duration
    /// Fast local moves usually finish in milliseconds. Recovery may keep
    /// running after this grace, but it never extends foreground failure UI.
    private let recoveryForegroundGrace: Duration
    /// Accessibility, WindowServer, and pasteboard calls are system edges.
    /// Cancellation-deaf implementations must not leave the controller in
    /// `.inserting` forever; an uncertain result is retained in memory.
    private let insertionDeadline: Duration
    /// Return is a separate irreversible system event after text already
    /// landed. It has its own shorter confirmation budget.
    private let returnDeadline: Duration
    /// Key-down destination supplied by a pre-populated system cache. This is
    /// deliberately a synchronous memory read: no AppKit/WindowServer call may
    /// sit between launching capture and publishing a cancellable session.
    private let targetApplicationSnapshot: @Sendable () -> TargetApplication?

    // MARK: - Session state

    /// Application into which we will insert the text.
    ///
    /// Removed at the moment the key is pressed, and not at the end: while it is running
    /// recognition, focus could go away, but the text must get to where it was dictated.
    private var targetApplication: TargetApplication?

    /// A key release that occurred before the recording began.
    ///
    /// Resets in exactly three places: at the start of the session, at its cancellation, and in
    /// final cleaning. A lost flag leaves recording enabled.
    private var deferredStopRequested = false

    private var cancellationRequested = false
    private var isHandsFree = false
    private var finalizationTask: Task<Void, Never>?
    private var preparingStopWatchdog: Task<Void, Never>?
    private var activeRecoveryTickets: [DictationSessionID: RecordingRecoveryTicket] = [:]
    private var currentDisposition: RecordingDisposition?
    private var recordingStartedAt: Date?
    /// The path returned at capture start remains the cancellation handle even
    /// while a stop operation is suspended before it can return its artifact.
    private var activeRecordingURL: URL?
    /// The moment the key is released is the start of the “stop → text” countdown.
    private var stopRequestedAt: ContinuousClock.Instant?
    /// Real monotonic anchor for the absolute foreground SLO. Kept separate
    /// from the injectable reporting clock so tests cannot accidentally mix
    /// clock domains in deadline arithmetic.
    private var stopSLORequestedAt: ContinuousClock.Instant?

    /// The number of the current session increases at each start.
    ///
    /// Cancellation does not interrupt an already started wait, but only marks it:
    /// recognition finishes reading its buffer and wakes up later - when the person
    /// managed to start the next dictation. Without a number, such a tail brought cleaning to a
    /// end and extinguished ANOTHER'S live session: the state showed “free”, and
    /// the microphone remained on, and there was nothing to get out of it.
    private var currentSession: DictationSessionID?
    private var overlayRevision: UInt64 = 0

    /// Whether this session has already asked for the person's attention.
    private var hasSoundedThisSession = false

    public init(
        capture: any AudioCapturing,
        transcribe: @escaping @Sendable (URL) async throws -> ASRResult,
        transcribeSamples: (@Sendable ([Float]) async throws -> ASRResult)? = nil,
        inserter: any TextInserting,
        targetApplicationSnapshot: (@Sendable () -> TargetApplication?)? = nil,
        overlay: any OverlayPresenting,
        sounds: any Sounding,
        recordingRecovery: any RecordingRecoveryStoring = DiscardingRecordingRecovery(),
        pipeline: @escaping () -> any TextProcessing = { TextPipeline() },
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        transcriptionDeadline: @escaping @Sendable (TimeInterval) -> Duration = TranscriptionDeadline.deadline(forAudioDuration:),
        prepareForTranscription: (@Sendable () async throws -> Void)? = nil,
        // Worst measured cold reload is ~16 s of ANE respecialization plus the
        // warm-up; 25 s covers it with margin while a genuine wedge still
        // surfaces well before the worker's own watchdog escalates.
        prepareDeadline: Duration = .seconds(25),
        enginePreparationNoticeDelay: Duration = .milliseconds(250),
        captureFreezeDeadline: Duration = .milliseconds(500),
        recordingReadableDeadline: Duration = .seconds(2),
        recordingPreserveDeadline: Duration = .seconds(2),
        recoveryForegroundGrace: Duration = .milliseconds(150),
        insertionDeadline: Duration = .seconds(2),
        returnDeadline: Duration = .seconds(1)
    ) {
        self.capture = capture
        self.transcribe = transcribe
        self.transcribeSamples = transcribeSamples
        self.inserter = inserter
        self.targetApplicationSnapshot = targetApplicationSnapshot
            ?? { inserter.frontmostApplication() }
        self.overlay = overlay
        self.sounds = sounds
        overlayDispatcher = DictationOverlayDispatcher(overlay: overlay)
        soundDispatcher = DictationSoundDispatcher(sounds: sounds)
        self.recordingRecovery = recordingRecovery
        self.pipeline = pipeline
        self.now = now
        self.monotonicNow = monotonicNow
        self.transcriptionDeadline = transcriptionDeadline
        self.prepareForTranscription = prepareForTranscription
        self.prepareDeadline = prepareDeadline
        self.enginePreparationNoticeDelay = enginePreparationNoticeDelay
        self.captureFreezeDeadline = captureFreezeDeadline
        self.recordingReadableDeadline = recordingReadableDeadline
        self.recordingPreserveDeadline = recordingPreserveDeadline
        self.recoveryForegroundGrace = recoveryForegroundGrace
        self.insertionDeadline = insertionDeadline
        self.returnDeadline = returnDeadline
    }

    // MARK: - Beginning

    /// Hotkey pressed.
    public func begin(handsFree: Bool, isEnabled: Bool, isModelReady: Bool) {
        // The first check is synchronous, before any waiting. Between her and
        // the asynchronous start is completed by pressing again.
        guard DictationStopPolicy.canStart(
            state: state,
            isEnabled: isEnabled,
            isModelReady: isModelReady
        ) else { return }

        let session = DictationSessionID()
        let disposition = RecordingDisposition()
        currentSession = session
        currentDisposition = disposition
        overlayRevision = 0
        // Do not touch the previous Copy/Retry: the new entry can be canceled or
        // fail with an error. Saved text is deleted only by an explicit action
        // or after a successful Retry.
        isHandsFree = handsFree
        cancellationRequested = false
        deferredStopRequested = false

        // Production supplies a lock-only destination cache. Capture ownership
        // is launched before callbacks and HUD work so none can clip the first
        // word. Adoption still happens on this actor with the session token.
        launchCapture(session: session, disposition: disposition)
        // Snapshot the destination before publishing `.preparing`: an observer
        // may activate our own settings window and change focus.
        targetApplication = targetApplicationSnapshot()
        state = .preparing

        guard isCurrent(session), state == .preparing, !cancellationRequested else { return }
        isHandsFreeActive = handsFree
        guard isCurrent(session), state == .preparing, !cancellationRequested else { return }
        guard isCurrent(session), state == .preparing, !cancellationRequested else { return }

        // The HUD is feedback, never a prerequisite for the microphone. A
        // wedged window server must not clip the first word or delay capture.
        presentOverlay(.preparing, elapsed: 0, session: session)
    }

    private func launchCapture(
        session: DictationSessionID,
        disposition: RecordingDisposition
    ) {
        let capture = capture
        // One stream per take. Built here rather than lazily so the sink is in
        // place before the first frame: a segment cut before anybody was
        // listening would be audio nobody ever recognizes.
        let streamed = transcribeSamples.map { StreamedSegmentRecognizer(transcribe: $0) }
        streamedSegments = streamed
        Task.detached(priority: .userInitiated) { [weak self] in
            // The sink hops nothing and holds nothing: `submit` is safe from
            // the capture's own queue and returns at once.
            let sink: (@Sendable ([Float]) -> Void)? = streamed.map { recognizer in
                { @Sendable samples in recognizer.submit(samples) }
            }
            await capture.setSegmentSink(sink)
            let outcome: CaptureStartOutcome
            do {
                outcome = .started(
                    try await capture.startRecording(
                        session: session,
                        disposition: disposition
                    )
                )
            } catch {
                outcome = .failed(String(describing: error))
            }
            guard let self else {
                disposition.requestDelete()
                if case let .started(url) = outcome {
                    await capture.abortRecording(session: session, expectedURL: url)
                }
                return
            }
            await self.captureDidStart(
                outcome,
                session: session,
                disposition: disposition
            )
        }
    }

    private func captureDidStart(
        _ outcome: CaptureStartOutcome,
        session: DictationSessionID,
        disposition: RecordingDisposition
    ) async {
        guard case let .started(startedURL) = outcome else {
            if case let .failed(message) = outcome {
                await fail(session: session, with: .capture(message))
            }
            return
        }

        // After waiting, the status is checked again - the cancellation could have come
        // exactly at the moment the engine starts.
        guard isCurrent(session), state == .preparing, !cancellationRequested else {
            // The recording has started, but the session is no longer there. We turn off our microphone -
            // otherwise it will remain on, and there will be nothing to stop it, -
            // but we don’t do the cleaning: it belongs to the session that is going on now.
            let capture = capture
            Task.detached(priority: .userInitiated) {
                if disposition.state == .deleteRequested {
                    await capture.abortRecording(session: session, expectedURL: startedURL)
                } else {
                    // A start that outlives a technical timeout/interruption is
                    // still the user's recording. Fence the exact generation,
                    // but never reinterpret recovery ownership as Escape.
                    await capture.containRecording(session: session, expectedURL: startedURL)
                }
            }
            // An interrupt/preserve task may already own the terminal outcome
            // and required notice. Do not let the late start steal its cleanup.
            if isCurrent(session), finalizationTask == nil {
                await finishWithoutInsertion(session: session)
            }
            return
        }

        activeRecordingURL = startedURL
        recordingStartedAt = now()
        state = .listening
        // `onStateChange` is an external reentrancy point: it may synchronously
        // stop or cancel. Never publish an obsolete Listening command or eat a
        // deferred stop belonging to that transition.
        guard isCurrent(session), state == .listening, !cancellationRequested else { return }
        presentOverlay(.listening, elapsed: 0, session: session)

        // The release that came while the engine was rising is processed here -
        // exactly once.
        //
        // Waiting for the first recorded frame used to follow, as the gate for
        // the start sound. The sound is gone (`Sounding`), and with it the
        // wait: the panel's "listening" promise above is deliberately not
        // frame-gated, because a silent device may never deliver a frame and
        // the person must still be able to stop the session.
        if deferredStopRequested {
            deferredStopRequested = false
            finish()
        }
    }

    // MARK: - Stop

    /// The hotkey is released (or pressed a second time in hands-free mode).
    public func stop() {
        switch DictationStopPolicy.decideStop(state: state, isHandsFree: isHandsFree) {
        case .stopNow:
            markStopRequested()
            finish()
        case .deferUntilListening:
            markStopRequested()
            deferredStopRequested = true
            if let session = currentSession { schedulePreparingStopWatchdog(session: session) }
        case .ignore, .noSession:
            break
        }
    }

    /// Stop in the mode without holding - by pressing the key a second time.
    public func stopHandsFree() {
        guard isHandsFree else { return }

        switch state {
        case .listening:
            markStopRequested()
            finish()
        case .preparing:
            // Same as releasing the key, only pressing: second
            // the press arrived before the engine rose. Lose it
            // not allowed - in this mode the key is not held down and the recording is stopped
            // nothing more: the microphone would stay on with no one listening.
            markStopRequested()
            deferredStopRequested = true
            if let session = currentSession { schedulePreparingStopWatchdog(session: session) }
        case .idle, .transcribing, .inserting:
            break
        }
    }

    /// Capture reached its bounded in-memory safety limit while disk spill was
    /// unavailable. Finish the complete retained take through the ordinary
    /// transcription path, independent of hotkey/hands-free gesture policy.
    /// This is a graceful capacity stop, not a capture failure.
    public func stopAtCaptureMemoryLimit() {
        guard let session = currentSession else { return }
        stopAtCaptureMemoryLimit(session: session)
    }

    /// Token-scoped form used by the asynchronously delivered capture limit
    /// observer. A late N callback can never stop N+1.
    public func stopAtCaptureMemoryLimit(session: DictationSessionID) {
        guard isCurrent(session) else { return }
        switch state {
        case .listening:
            markStopRequested()
            finish()
        case .preparing:
            markStopRequested()
            deferredStopRequested = true
            if let session = currentSession { schedulePreparingStopWatchdog(session: session) }
        case .idle, .transcribing, .inserting:
            break
        }
    }

    /// Switch the ongoing session to non-holding mode.
    ///
    /// The double click comes after the first one has launched the session, and
    /// the first release tried to finish it. Start new at this moment
    /// it is impossible - it would not pass the check for a free state, and the mode
    /// would remain unattainable. Therefore, we switch the current one.
    ///
    /// Delayed release is reset: it belonged to the previous gesture, and in
    /// in the new mode the key is supposed to be released.
    public func promoteToHandsFree() {
        guard state == .preparing || state == .listening else { return }
        // Commit every internal mode transition before publishing the external
        // hands-free callback. That callback is reentrant and may immediately
        // stop the session; clearing its newly accepted stop afterwards would
        // leave the microphone recording forever.
        isHandsFree = true
        deferredStopRequested = false
        preparingStopWatchdog?.cancel()
        preparingStopWatchdog = nil
        stopRequestedAt = nil
        stopSLORequestedAt = nil
        isHandsFreeActive = true
    }

    private func finish() {
        // Finalization runs exactly once: otherwise the text will be inserted twice.
        guard finalizationTask == nil, state == .listening else { return }

        // One input for all four stop paths: stop, stopHandsFree,
        // and delayed release - everyone comes here.
        markStopRequested()
        preparingStopWatchdog?.cancel()
        preparingStopWatchdog = nil
        guard let session = currentSession else { return }
        let task = Task { [weak self] in
            await self?.finalize(session: session)
            await MainActor.run { self?.forgetFinalization(session: session) }
        }
        finalizationTask = task
        state = .transcribing
        guard isCurrent(session), state == .transcribing, !cancellationRequested else { return }
        presentOverlay(.transcribing, elapsed: elapsedSeconds(), session: session)
    }

    private func schedulePreparingStopWatchdog(session: DictationSessionID) {
        guard preparingStopWatchdog == nil, let stopSLORequestedAt else { return }
        let deadline = stopSLORequestedAt.advanced(by: captureFreezeDeadline)
        let task = Task { [weak self] in
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            guard !Task.isCancelled else { return }
            await self?.preparingStopExpired(session: session)
        }
        preparingStopWatchdog = task
    }

    private func preparingStopExpired(session: DictationSessionID) async {
        guard isCurrent(session), state == .preparing, deferredStopRequested else { return }
        let owner = preparingStopWatchdog
        preparingStopWatchdog = nil
        finalizationTask = owner
        cancellationRequested = true
        currentDisposition?.keepInBackground()
        state = .transcribing
        guard !Task.isCancelled, isCurrent(session) else { return }

        let capture = capture
        Task.detached(priority: .userInitiated) {
            await capture.containRecording(session: session, expectedURL: nil)
        }
        let notice = DictationNotice(
            kind: .failure,
            message: "Starting the microphone took too long. Dictation was stopped.",
            wordsDidNotLand: true
        )
        await report(notice, session: session, allowCancellation: true)
        await cleanup(session: session)
    }

    /// Whether the panel is currently telling someone that the model is still
    /// loading. Kept so the retraction is exactly as conditional as the
    /// announcement: a `false` nobody was told about would be a lie of its own.
    private var isAnnouncingEngineWait = false

    private func beginEngineWaitAnnouncement() {
        guard !isAnnouncingEngineWait else { return }
        isAnnouncingEngineWait = true
        onEnginePreparationWait?(true)
    }

    private func endEngineWaitAnnouncement() {
        guard isAnnouncingEngineWait else { return }
        isAnnouncingEngineWait = false
        onEnginePreparationWait?(false)
    }

    private func markStopRequested() {
        if stopRequestedAt == nil {
            stopRequestedAt = monotonicNow()
            stopSLORequestedAt = .now
        }
    }

    /// Forget the completed task - but only if it is still our session.
    private func forgetFinalization(session: DictationSessionID) {
        guard isCurrent(session) else { return }
        finalizationTask = nil
        preparingStopWatchdog?.cancel()
        preparingStopWatchdog = nil
    }

    private func freezeCapture(
        session: DictationSessionID,
        expectedURL: URL
    ) async throws -> CapturedRecording {
        do {
            let budget: Duration
            if let stopSLORequestedAt {
                budget = try remainingBudget(
                    until: stopSLORequestedAt.advanced(by: captureFreezeDeadline),
                    stageMaximum: captureFreezeDeadline
                )
            } else {
                budget = captureFreezeDeadline
            }
            return try await withTranscriptionDeadline(budget) { [capture] in
                try await capture.freezeRecording(session: session, expectedURL: expectedURL)
            }
        } catch is TranscriptionTimeout {
            throw RecordingFinalizationTimeout(stage: .freeze)
        }
    }

    private func readableURL(for recording: CapturedRecording) async throws -> URL {
        do {
            return try await withTranscriptionDeadline(recordingReadableDeadline) {
                try await recording.readableURL()
            }
        } catch is TranscriptionTimeout {
            throw RecordingFinalizationTimeout(stage: .readableFile)
        }
    }

    private func recoverySourceURL(
        for recording: CapturedRecording
    ) async throws -> (url: URL, rebuiltFromPCM: Bool) {
        do {
            return (try await readableURL(for: recording), false)
        } catch let readableFailure {
            let rebuilt = try await withTranscriptionDeadline(recordingPreserveDeadline) {
                try await recording.materializedRecoveryURL()
            }
            guard let rebuilt else { throw readableFailure }
            return (rebuilt, true)
        }
    }

    /// Move a proven-readable take into safekeeping and word the outcome.
    /// A zero-header or still-draining file is left in Takes for launch-time
    /// repair instead of being advertised as a usable recovery recording.
    private func preserveForRetry(
        _ recording: CapturedRecording,
        session: DictationSessionID
    ) async -> (saved: URL?, suffix: String) {
        defer {
            if !isCurrent(session) { activeRecoveryTickets[session] = nil }
        }
        do {
            let source = try await recoverySourceURL(for: recording)
            let ticket = recordingRecovery.beginPreserve(source.url)
            if recording.disposition.state == .deleteRequested {
                ticket.requestDelete()
            }
            activeRecoveryTickets[session] = ticket
            let outcome = try await withTranscriptionDeadline(recordingPreserveDeadline) {
                await ticket.value()
            }
            let saved: URL?
            switch outcome {
            case let .committed(url):
                if recording.disposition.markPublished() {
                    saved = url
                    // No await follows before the notice is queued and cleanup
                    // commits, so Escape cannot race this publication point.
                    ticket.markPublished()
                } else {
                    ticket.requestDelete()
                    saved = nil
                }
            case .busy:
                saved = nil
            case .deleted:
                saved = nil
            case let .notCommitted(_, reason):
                return (nil, " The recording couldn't be kept: \(reason)")
            }
            if source.rebuiltFromPCM, saved != nil {
                // The complete rebuilt WAV is now in Recovery. The original
                // file belongs to a failed/possibly wedged writer and may be
                // truncated; unlinking its path is safe even while its old FD
                // is still being released.
                RecordingFileDisposer.shared.submit(recording.url)
            }
            return (
                saved,
                saved == nil
                    ? " The recording couldn't be kept."
                    : " The recording is kept on this Mac for a few days"
                        + " (Settings → About → Reveal Support Folder)."
            )
        } catch is RecordingFinalizationTimeout {
            return (
                nil,
                " The local take will be checked for automatic recovery on the next launch."
            )
        } catch is TranscriptionTimeout {
            return (
                nil,
                " Local safekeeping did not finish in time; automatic recovery will check the take on the next launch."
            )
        } catch {
            return (
                nil,
                " Safekeeping failed: \(error.localizedDescription). The local take will be checked on the next launch."
            )
        }
    }

    private func preserveWithinForegroundGrace(
        _ recording: CapturedRecording,
        session: DictationSessionID
    ) async -> (saved: URL?, suffix: String) {
        let background = Task { [weak self] in
            guard let self else {
                return (saved: URL?.none, suffix: " The recording couldn't be kept.")
            }
            return await self.preserveForRetry(recording, session: session)
        }
        do {
            return try await withTranscriptionDeadline(recoveryForegroundGrace) {
                await background.value
            }
        } catch {
            return (
                nil,
                " Local safekeeping is continuing in the background; automatic recovery will keep the take on this Mac even if Retry is not shown immediately."
            )
        }
    }

    /// Put a streamed take together: the pieces already recognized, plus the
    /// tail nobody has looked at yet.
    ///
    /// The tail is the only decode the person actually waits for, which is the
    /// whole point of the exercise. It is also the one piece that can be too
    /// short to trust on its own — when the key comes up just after a cut —
    /// and in that case the segment before it is taken back and the two are
    /// recognized together rather than shipping a fragment.
    private static func joinStreamed(
        texts: [String],
        segmentSampleCounts: [Int],
        consumedSamples: Int,
        samples: [Float],
        transcribe: @Sendable ([Float]) async throws -> ASRResult
    ) async throws -> ASRResult {
        var pieces = texts
        var tailStart = min(max(0, consumedSamples), samples.count)

        if samples.count - tailStart < minimumTailSamples,
           pieces.count == segmentSampleCounts.count,
           let last = segmentSampleCounts.last {
            pieces.removeLast()
            tailStart = max(0, tailStart - last)
        }

        var processing = 0.0
        var dispatch = 0.0
        let tail = Array(samples[tailStart...])
        if !tail.isEmpty {
            let result = try await transcribe(tail)
            pieces.append(result.text)
            processing = result.processingDuration
            dispatch = result.engineDispatchDuration
        }

        let text = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // The durations describe the tail, and that is deliberate: they are what
        // the person waited for after letting go of the key. Reporting the sum
        // of every segment would be arithmetically true and describe a wait
        // nobody had.
        return ASRResult(
            text: text,
            words: [],
            audioDuration: Double(samples.count) / Double(sampleRate),
            processingDuration: processing,
            engineDispatchDuration: dispatch
        )
    }

    private func finalize(session: DictationSessionID) async {
        let recording: CapturedRecording
        do {
            guard shouldContinue(session), let expectedURL = activeRecordingURL else {
                await finishWithoutInsertion(session: session)
                return
            }
            recording = try await freezeCapture(session: session, expectedURL: expectedURL)
        } catch let timeout as RecordingFinalizationTimeout where timeout.stage == .freeze {
            guard shouldContinue(session) else {
                await finishWithoutInsertion(session: session)
                return
            }
            if let expectedURL = activeRecordingURL {
                let capture = capture
                Task.detached(priority: .userInitiated) {
                    await capture.containRecording(session: session, expectedURL: expectedURL)
                }
            }
            currentDisposition?.keepInBackground()
            let notice = DictationNotice(
                kind: .failure,
                message: "Stopping the recording took too long. The local take will be checked for automatic recovery.",
                wordsDidNotLand: true
            )
            await report(notice, session: session)
            await cleanup(session: session)
            return
        } catch {
            guard shouldContinue(session) else {
                await finishWithoutInsertion(session: session)
                return
            }
            await fail(session: session, with: .capture(String(describing: error)))
            return
        }
        // The capture is behind us. Marking it here, before any branch below,
        // keeps the stage boundary at the causal event rather than at whatever
        // check happens to run next.
        let freezeCompletedAt = monotonicNow()
        let bufferedSamples = recording.samples

        guard shouldContinue(session) else {
            await discard(recording.url, session: session)
            await finishWithoutInsertion(session: session)
            return
        }

        // Pressed and immediately released - nothing to recognize. The engine on such
        // records refuse to work, but show an error because of this
        // incorrect: the person simply changed his mind.
        //
        // The recorded audio alone does not tell these two stories apart. The key,
        // held for a dozen seconds against a muted, dead or occupied microphone,
        // gives exactly the same empty recording - and being silent about it means
        // eating up an entire dictated paragraph without a single word of
        // explanation. Therefore, the hold is asked here, and this is the only
        // place where the session needs it.
        guard DictationDurationPolicy.isWorthTranscribing(duration: recording.duration) else {
            let outcome = DictationDurationPolicy.outcomeForShortRecording(held: elapsedSeconds())
            await discard(recording.url, session: session)
            switch outcome {
            case .dropSilently:
                await finishWithoutInsertion(session: session)
            case .reportSilentInput:
                let notice = DictationNotice(
                    kind: .failure,
                    message: "The microphone recorded nothing — check that the right input device is selected and not muted."
                )
                await report(notice, session: session)
                await cleanup(session: session)
            }
            return
        }

        let recognized: ASRResult
        // Stage boundaries for the speed report. Both are plain clock reads on
        // the path that already runs; neither adds a suspension point, a lock,
        // or a reordered call.
        var preparationCompletedAt: ContinuousClock.Instant?
        // The wait for the recording to be written and closed. Local to the
        // take, because it describes this take and nothing else.
        let readableWaitBox = DurationBox()
        // The instant the recognition call is dispatched. Take-scoped because
        // the report is built outside the block that stamps it.
        let dispatchBox = DurationBox()
        let pickedUpBox = DurationBox()
        let workDoneBox = DurationBox()
        let returnedBox = DurationBox()
        let returnFrameBox = MeasurementBox<Bool>()
        do {
            var foregroundEnd = (stopSLORequestedAt ?? .now).advanced(
                by: captureFreezeDeadline + transcriptionDeadline(recording.duration)
            )
            // A residency-managed engine may be cold here; the reload has
            // been running under the person's voice since the keypress.
            // Waiting it out and inserting the words beats abandoning them,
            // so the stop→text promise excludes the reload: the foreground
            // deadline is re-anchored by however long preparation actually
            // took, and only then does the recognition deadline count.
            // `prepareDeadline` stays under the worker's 30 s per-phase
            // watchdog, so a genuinely wedged load surfaces here first and
            // recovery stays with the worker.
            if let prepareForTranscription {
                let prepareStarted = ContinuousClock.now
                // A resident engine answers this in microseconds, and flipping
                // the panel to a loading message for every take would be a
                // flicker on the overwhelmingly common path. The wait is
                // announced only once it is long enough for someone to be
                // looking at it, and retracted on every exit.
                let announcement = Task { [weak self, enginePreparationNoticeDelay] in
                    try? await Task.sleep(for: enginePreparationNoticeDelay)
                    guard !Task.isCancelled else { return }
                    self?.beginEngineWaitAnnouncement()
                }
                defer {
                    announcement.cancel()
                    endEngineWaitAnnouncement()
                }
                do {
                    try await withTranscriptionDeadline(prepareDeadline) {
                        try await prepareForTranscription()
                    }
                } catch is TranscriptionTimeout {
                    throw DictationPreparationTimeout()
                }
                foregroundEnd = foregroundEnd.advanced(
                    by: prepareStarted.duration(to: .now)
                )
                preparationCompletedAt = monotonicNow()
            }
            // The deadline stands between the person and a wedged engine: a
            // CoreML prediction stuck on a dead system service ignores
            // cancellation and would hold "Transcribing…" forever.
            let inferenceBudget = try remainingBudget(
                until: foregroundEnd,
                stageMaximum: transcriptionDeadline(recording.duration)
            )
            // Stamped on this side of the deadline wrapper. Everything between
            // here and the engine's own clock is transport: hopping executors,
            // entering an actor, waiting for a thread. That span held the whole
            // of every slow take and had no number, because every previous
            // stamp sat past it.
            let dispatchedAt = monotonicNow()
            let clockNow = monotonicNow
            // The explicit type is load-bearing. If this closure inherited
            // MainActor isolation, the return hop would become a plausible zero.
            let streamed = streamedSegments
            let consumedSamples = recording.consumedSampleCount
            let framedRecognition: @Sendable () async throws -> ASRResult = {
                [transcribe, transcribeSamples, streamed, consumedSamples] in
                pickedUpBox.set(dispatchedAt.duration(to: clockNow()))
                defer {
                    returnFrameBox.set(pthread_main_np() != 0)
                    returnedBox.set(dispatchedAt.duration(to: clockNow()))
                }
                return try await withTranscriptionDeadline(inferenceBudget) {
                    // The moment the pool actually picked this up. Everything
                    // before it is the hop off the main actor; everything after is
                    // reaching the engine. `transport` covered both as one number,
                    // and the two need different remedies — so they are separated
                    // before either is attempted.
                    // Covers memory, file and error exits. Catch paths return
                    // without reading this because timed-out work may finish later.
                    defer { workDoneBox.set(dispatchedAt.duration(to: clockNow())) }
                    if let transcribeSamples, let bufferedSamples, !bufferedSamples.isEmpty {
                        // Whatever was recognized while the person was still
                        // talking. `finish` waits for the segment in flight
                        // rather than cancelling it: cancelling would save a
                        // few tens of milliseconds and cost a full re-decode of
                        // audio whose text is still needed.
                        let outcome = await streamed?.finish()
                        if case let .recognized(texts) = outcome, !texts.isEmpty {
                            return try await Self.joinStreamed(
                                texts: texts,
                                segmentSampleCounts: streamed?.submittedSampleCounts ?? [],
                                consumedSamples: consumedSamples,
                                samples: bufferedSamples,
                                transcribe: transcribeSamples
                            )
                        }
                        // No cuts were made, or a segment failed. Either way the
                        // whole take is recognized here exactly as it always
                        // was — a stream that could not finish costs latency,
                        // never words.
                        return try await transcribeSamples(bufferedSamples)
                    }
                    let readableStart = clockNow()
                    let url = try await self.readableURL(for: recording)
                    readableWaitBox.set(readableStart.duration(to: clockNow()))
                    return try await transcribe(url)
                }
            }
            recognized = try await framedRecognition()
            dispatchBox.set(dispatchedAt.duration(to: monotonicNow()))
        } catch let timeout as RecordingFinalizationTimeout where timeout.stage == .readableFile {
            guard shouldContinue(session) else {
                await discard(recording.url, session: session)
                await finishWithoutInsertion(session: session)
                return
            }
            let notice = DictationNotice(
                kind: .failure,
                message: "Finishing the local recording took too long. The unfinished file will be checked for automatic recovery.",
                wordsDidNotLand: true
            )
            await report(notice, session: session)
            await cleanup(session: session)
            return
        } catch is DictationPreparationTimeout {
            guard shouldContinue(session) else {
                await discard(recording.url, session: session)
                await finishWithoutInsertion(session: session)
                return
            }
            // A cold generation may still be loading normally. Free the
            // foreground session and keep the take, but do not signal the
            // inference-stall hook: the worker's preparation watchdog owns
            // kill, fencing, and recovery if that load is genuinely wedged.
            recording.disposition.keepInBackground()
            currentDisposition?.keepInBackground()
            let (saved, suffix) = await preserveWithinForegroundGrace(recording, session: session)
            guard shouldContinue(session) else {
                await discard(saved ?? recording.url, session: session)
                await finishWithoutInsertion(session: session)
                return
            }
            let notice = DictationNotice(
                kind: .failure,
                message: "The speech model is still getting ready; this take was not discarded." + suffix,
                recoveryAudio: saved
            )
            await report(notice, session: session)
            await cleanup(session: session)
            return
        } catch is TranscriptionTimeout {
            guard shouldContinue(session) else {
                await discard(recording.url, session: session)
                await finishWithoutInsertion(session: session)
                return
            }
            // Signal containment at the moment the deadline is known. Recovery
            // file I/O and user feedback must never postpone worker fencing.
            onTranscriptionStall?()
            recording.disposition.keepInBackground()
            currentDisposition?.keepInBackground()
            let (saved, suffix) = await preserveWithinForegroundGrace(recording, session: session)
            guard shouldContinue(session) else {
                await discard(saved ?? recording.url, session: session)
                await finishWithoutInsertion(session: session)
                return
            }
            let notice = DictationNotice(
                kind: .failure,
                message: "Transcribing took too long and was stopped." + suffix,
                recoveryAudio: saved
            )
            await report(notice, session: session)
            await cleanup(session: session)
            return
        } catch {
            // A cancellation that came while the engine was running is more important than its failure. Otherwise
            // Escape would leave exactly the trace it gets rid of:
            // the voice and failure message saved for Retry are already on top of that one
            // the session that the person started next.
            guard shouldContinue(session) else {
                await discard(recording.url, session: session)
                await finishWithoutInsertion(session: session)
                return
            }
            recording.disposition.keepInBackground()
            currentDisposition?.keepInBackground()
            let (saved, suffix) = await preserveWithinForegroundGrace(recording, session: session)
            guard shouldContinue(session) else {
                await discard(saved ?? recording.url, session: session)
                await finishWithoutInsertion(session: session)
                return
            }
            let notice = DictationNotice(
                kind: .failure,
                message: DictationError.recognition(String(describing: error)).userMessage + suffix,
                recoveryAudio: saved
            )
            await report(notice, session: session)
            await cleanup(session: session)
            return
        }

        // Check after each wait: while recognition was in progress, the user
        //could press cancel.
        guard shouldContinue(session) else {
            await discard(recording.url, session: session)
            await finishWithoutInsertion(session: session)
            return
        }

        // t1: the engine returned the text. Removed before all checks below, so that
        // the number did not hit our own branch.
        let recognizedAt = monotonicNow()
        // Diagnostic timing is frozen with this exact take. Reading mutable
        // capture state here used to add an actor wait after ASR and let an old
        // session resume inside the next one.
        let microphoneStartup = recording.startupLatency
        let insertionTarget = targetApplication
        // Recognition owns everything after preparation; without a preparation
        // hook it owns everything after the freeze. `stopRequestedAt` is set on
        // every path that reaches here, so the freeze stage is never guessed.
        let recognitionStartedAt = preparationCompletedAt ?? freezeCompletedAt
        // Zero unless the take was actually cut, which is what the log needs to
        // distinguish "fast because it was short" from "fast because most of it
        // was already done".
        let streamedSegmentCount = streamedSegments?.recognizedCount ?? 0
        let phases = stopRequestedAt.map { stopMark in
            DictationPhaseBreakdown(
                captureFreeze: stopMark.duration(to: freezeCompletedAt),
                enginePreparation: preparationCompletedAt.map {
                    freezeCompletedAt.duration(to: $0)
                },
                recognition: recognitionStartedAt.duration(to: recognizedAt),
                engineProcessing: recognized.processingDuration > 0
                    ? .seconds(recognized.processingDuration)
                    : nil,
                engineQueueing: recognized.queueingDuration > 0
                    ? .seconds(recognized.queueingDuration)
                    : nil,
                audioDecoding: recognized.decodingDuration > 0
                    ? .seconds(recognized.decodingDuration)
                    : nil,
                recordingReadable: readableWaitBox.get(),

                // What it cost to reach the engine at all, engine time removed.
                // A large number here means the work was waiting, not working.
                // How long the hop off the main actor took on its own.
                executorHandover: pickedUpBox.get(),
                poolReturn: Self.positiveDifference(
                    later: returnedBox.get(),
                    earlier: workDoneBox.get()
                ),
                mainActorReturn: Self.positiveDifference(
                    later: dispatchBox.get(),
                    earlier: returnedBox.get()
                ),
                engineDispatch: recognized.engineDispatchDuration > 0
                    ? .seconds(recognized.engineDispatchDuration)
                    : nil,
                returnFrameWasMainThread: returnFrameBox.get(),
                engineTransport: {
                    guard let whole = dispatchBox.get() else { return nil }
                    let inside = recognized.processingDuration
                    let outside = (Double(whole.components.seconds)
                        + Double(whole.components.attoseconds) / 1e18) - inside
                    return outside > 0 ? .seconds(outside) : nil
                }(),
                audioDuration: .seconds(recognized.audioDuration),
                streamedSegments: streamedSegmentCount
            )
        }

        guard shouldContinue(session) else {
            await discard(recording.url, session: session)
            await finishWithoutInsertion(session: session)
            return
        }

        let run = pipeline().run(recognized.text)
        let processed = run.output
        guard !processed.text.isEmpty else {
            // An empty result is not an error: the person could remain silent, speak
            // too quiet or using the wrong microphone. But one cannot remain silent in response:
            // a blank panel without text is indistinguishable from “inserted in the wrong place”, and
            // a person goes to look for the missing phrase in someone else's window. Too
            // short press does not go here - it is filtered out above and explanations
            // not required.
            await discard(recording.url, session: session)
            let notice = DictationNotice(
                kind: .info,
                message: "Nothing was recognized — nothing was inserted.",
                wordsDidNotLand: true
            )
            await report(notice, session: session)
            await cleanup(session: session)
            return
        }

        await insert(
            processed,
            provenance: run.provenance,
            recognizedAt: recognizedAt,
            microphoneStartup: microphoneStartup,
            phases: phases,
            target: insertionTarget,
            session: session
        )
        // The last moment the take still exists. Whoever keeps a history has to
        // take its copy now; the next line deletes the original, and that
        // deletion is the promise that a recording does not outlive its use.
        onTakeFinished?(processed.text, recording.url)
        await discard(recording.url, session: session)
    }

    /// Collect a speed report and send it outside.
    ///
    /// Without the release mark, there is no report at all: counting “stop → text” is not from
    /// what, but to show a number calculated from something else is to lie.
    private func reportSpeed(
        recognizedAt: ContinuousClock.Instant,
        marks: InsertionMarks,
        microphoneStartup: Duration?,
        phases: DictationPhaseBreakdown?
    ) {
        guard let onSpeed, let stopRequestedAt else { return }
        onSpeed(
            DictationSpeedReport(
                toRecognizedText: stopRequestedAt.duration(to: recognizedAt),
                toPasteDispatched: marks.pasteDispatchedAt.map { stopRequestedAt.duration(to: $0) },
                toClipboardRestored: marks.clipboardRestoredAt.map { stopRequestedAt.duration(to: $0) },
                microphoneStartup: microphoneStartup,
                phases: phases
            )
        )
    }

    private func insert(
        _ output: TextPipeline.Output,
        provenance: PipelineProvenance,
        recognizedAt: ContinuousClock.Instant,
        microphoneStartup: Duration?,
        phases: DictationPhaseBreakdown?,
        target: TargetApplication?,
        session: DictationSessionID
    ) async {
        guard shouldContinue(session) else { return }
        state = .inserting
        // Cmd+V is the meaningful completion feedback. Do not leave a redundant
        // “Inserting” panel over the destination application while the clipboard is
        // restored in the background.
        dismissOverlay(session: session)

        // Last point where cancellation is still possible. Then the event goes into
        // someone else's application and does not respond.
        guard shouldContinue(session) else {
            await finishWithoutInsertion(session: session)
            return
        }

        let marks: InsertionMarks
        do {
            let inserter = inserter
            marks = try await withTranscriptionDeadline(insertionDeadline) {
                try await inserter.insertReportingMarks(output.text, into: target)
            }
        } catch is TranscriptionTimeout {
            guard shouldContinue(session) else { return }
            await handleInsertionTimeout(text: output.text, session: session)
            return
        } catch {
            guard shouldContinue(session) else { return }
            await handleInsertionFailure(error, text: output.text, session: session)
            return
        }

        // Paste may already be irreversible, but a late completion from an old
        // session must not mutate callbacks, history, UI, or the next session.
        guard shouldContinue(session) else { return }
        onTextInserted?(output.text)
        // Origin - only after a successful insertion: unsuccessful insertion does not
        // “what the person saw” and “copy verbatim” she has nothing to give.
        onDictationCompleted?(provenance)
        reportSpeed(
            recognizedAt: recognizedAt,
            marks: marks,
            microphoneStartup: microphoneStartup,
            phases: phases
        )

        // The click is parsed separately from the insertion intentionally. These are different
        // system calls, and the second one fails when the first one is alive - for example,
        // when the user never released the modifier.
        if output.command == .pressReturn {
            do {
                let inserter = inserter
                try await withTranscriptionDeadline(returnDeadline) {
                    try await inserter.pressReturn(into: target)
                }
            } catch {
                guard shouldContinue(session) else { return }
                await reportReturnFailure(session: session)
                return
            }
            guard shouldContinue(session) else { return }
        }
        await cleanup(session: session)
    }

    /// The system edge did not return, so we cannot truthfully claim either
    /// success or failure: a synchronous event post may have crossed its
    /// irreversible boundary before the watchdog fired. Keep a copy and tell
    /// the person exactly that, while freeing the next dictation immediately.
    private func handleInsertionTimeout(text: String, session: DictationSessionID) async {
        pendingRecovery = RecoveredDictation(text: text)
        let notice = DictationNotice(
            kind: .warning,
            message: "Insertion couldn't be confirmed in time. The text is saved in the menu and may already have been pasted.",
            recoverableText: text,
            wordsDidNotLand: true
        )
        await report(notice, session: session)
        await cleanup(session: session)
    }

    /// The text was inserted, but pressing Return failed.
    ///
    /// The general denial thread would lie twice here: it would say “the text is not
    /// inserted" when it is in place, and would save a second copy of the dictated
    /// to disk. The private tool does not add up what is said without reason.
    private func reportReturnFailure(session: DictationSessionID) async {
        let notice = DictationNotice(
            kind: .warning,
            message: "The text was inserted, but pressing Return failed."
        )
        await report(notice, session: session)
        await cleanup(session: session)
    }

    /// The text was recognized, but it was not possible to insert it - we save it so that it does not disappear.
    private func handleInsertionFailure(
        _ error: Error,
        text: String,
        session: DictationSessionID
    ) async {
        if let insertion = error as? TextInsertionError,
           insertion == .insertedButClipboardRestoreFailed {
            let notice = DictationNotice(
                kind: .warning,
                message: "The text was inserted, but the previous clipboard couldn't be restored."
            )
            await report(notice, session: session)
            await cleanup(session: session)
            return
        }
        pendingRecovery = RecoveredDictation(text: text)

        let message: String
        if let insertion = error as? TextInsertionError {
            switch insertion {
            case .secureInputActive:
                // Not a failure, but a normal situation: the password field is active.
                message = "Text not inserted: secure input is active. Your text is saved in the menu."
            case .insertionInProgress:
                message = "A previous paste is still finishing. Your text is saved in the menu."
            default:
                message = "The text couldn't be inserted. It's saved in the menu."
            }
        } else {
            message = "The text couldn't be inserted. It's saved in the menu."
        }

        let notice = DictationNotice(
            kind: .warning,
            message: message,
            recoverableText: text,
            wordsDidNotLand: true
        )
        await report(notice, session: session)
        await cleanup(session: session)
    }

    // MARK: - Cancel

    /// Cancel dictation.
    public func cancel() {
        guard DictationStopPolicy.canCancel(state: state) else { return }

        // The order is important: first the flag, then cancel the task. Canceling a task does not
        // interrupts an already ongoing wait, and the flag is checked after each of them.
        cancellationRequested = true
        currentDisposition?.requestDelete()
        if let session = currentSession { activeRecoveryTickets[session]?.requestDelete() }
        finalizationTask?.cancel()

        guard let session = currentSession else { return }
        let recordingURL = activeRecordingURL
        let capture = capture
        Task.detached(priority: .userInitiated) {
            await capture.abortRecording(session: session, expectedURL: recordingURL)
        }
        // Filesystem/AVAudio containment is session-scoped and continues in
        // the background. It must never own the controller's return to idle.
        Task { [weak self] in
            await self?.finishWithoutInsertion(session: session)
        }
    }

    /// The recording failed on its own - for example, the disk ran out of space.
    ///
    /// This is not a cancellation: the user did not click anything and continues to talk.
    /// Therefore, we stop immediately and explain the reason, and do not wait until he
    /// finishes a phrase that there is nowhere to write down.
    public func interrupt(reason message: String) {
        guard let session = currentSession else { return }
        interrupt(session: session, reason: message)
    }

    /// Token-scoped live failure delivery. Validation happens at the final
    /// MainActor mutation point, after every observer/queue hop.
    public func interrupt(session: DictationSessionID, reason message: String) {
        guard isCurrent(session) else { return }
        guard state == .preparing || state == .listening else { return }
        guard finalizationTask == nil else { return }

        cancellationRequested = true
        currentDisposition?.keepInBackground()
        markStopRequested()
        let notice = DictationNotice(kind: .failure, message: message)
        let recordingURL = activeRecordingURL
        let task = Task { [weak self] in
            guard let self else { return }
            let capture = self.capture
            Task.detached(priority: .userInitiated) {
                await capture.containRecording(session: session, expectedURL: recordingURL)
            }
            guard !Task.isCancelled, self.isCurrent(session) else {
                await self.finishWithoutInsertion(session: session)
                return
            }
            // Through `report`: the interruption loses the words, and the
            // person mid-sentence learns of it by ear like any other loss.
            // Capture is already detached; feedback cannot keep the mic on.
            await self.report(notice, session: session, allowCancellation: true)
            await self.finishWithoutInsertion(session: session)
        }
        finalizationTask = task
        state = .transcribing
    }

    /// System permission or device disappeared while recording.
    /// Close the WAV and save it for an explicit Retry/Delete without trying
    /// recognize or insert into an already untrusted system state.
    public func preserveActiveRecording(reason message: String) {
        guard state == .preparing || state == .listening else { return }
        if state == .preparing {
            guard finalizationTask == nil, let session = currentSession else { return }
            cancellationRequested = true
            currentDisposition?.keepInBackground()
            markStopRequested()
            let notice = DictationNotice(kind: .failure, message: message)
            let recordingURL = activeRecordingURL
            let task = Task { [weak self] in
                guard let self else { return }
                let capture = self.capture
                Task.detached(priority: .userInitiated) {
                    await capture.containRecording(session: session, expectedURL: recordingURL)
                }
                guard !Task.isCancelled, self.isCurrent(session) else {
                    await self.finishWithoutInsertion(session: session)
                    return
                }
                // Through `report`, not around it: the notice must carry the
                // attention sound like every other surfaced failure.
                await self.report(notice, session: session, allowCancellation: true)
                await self.finishWithoutInsertion(session: session)
            }
            finalizationTask = task
            state = .transcribing
            return
        }
        guard finalizationTask == nil else { return }

        guard let session = currentSession else { return }
        currentDisposition?.keepInBackground()
        markStopRequested()
        let task = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                await self.cleanup(session: session)
                return
            }
            let recording: CapturedRecording?
            do {
                guard let expectedURL = self.activeRecordingURL else {
                    throw AudioCaptureError.notRecording
                }
                recording = try await self.freezeCapture(
                    session: session,
                    expectedURL: expectedURL
                )
            } catch {
                recording = nil
                let capture = self.capture
                let expectedURL = self.activeRecordingURL
                Task.detached(priority: .userInitiated) {
                    await capture.containRecording(
                        session: session,
                        expectedURL: expectedURL
                    )
                }
            }

            // While the file was closing, the person could press Escape. From now on
            // dictation has one outcome - cancellation, and it is more important than salvation: closed
            // WAV will no longer delete the recording interruption, and the saved one would go into the folder
            // repeat contrary to the promise “the canceled dictation is deleted.” At the same time
            // keep quiet: the failure message would fall on top of the session that
            // the man started next.
            guard !Task.isCancelled else {
                if let recording { await self.discard(recording.url, session: session) }
                await self.cleanup(session: session)
                return
            }

            let notice: DictationNotice
            if let recording,
               !DictationDurationPolicy.isWorthTranscribing(duration: recording.duration) {
                // The device vanished a moment after the start: the take holds
                // not a single word, there is nothing to rescue. The main path
                // deletes such fragments silently — here we name the reason of
                // the interruption and nothing else, otherwise a one-second
                // device hiccup leaves a "recording for retry" whose retry can
                // only ever produce an empty result.
                await self.discard(recording.url, session: session)
                notice = DictationNotice(kind: .failure, message: message)
            } else {
                var saved: URL?
                var suffix = " The recording couldn't be kept."
                if let recording {
                    let outcome = await self.preserveWithinForegroundGrace(
                        recording,
                        session: session
                    )
                    saved = outcome.saved
                    suffix = outcome.suffix
                    guard !Task.isCancelled else {
                        await self.discard(saved ?? recording.url, session: session)
                        await self.cleanup(session: session)
                        return
                    }
                }
                notice = DictationNotice(
                    kind: .failure,
                    message: message + suffix,
                    recoveryAudio: saved
                )
            }
            await self.report(notice, session: session)
            await self.cleanup(session: session)
        }
        finalizationTask = task
        state = .transcribing
    }

    // MARK: - Completion

    /// Is the session for which the wait began still ongoing?
    private func isCurrent(_ session: DictationSessionID) -> Bool { session == currentSession }

    private func shouldContinue(_ session: DictationSessionID) -> Bool {
        guard isCurrent(session) else { return false }
        return DictationFinalizationPolicy.shouldContinue(
            state: state,
            cancellationRequested: cancellationRequested,
            taskCancelled: Task.isCancelled
        )
    }

    private func fail(session: DictationSessionID, with error: DictationError) async {
        // There is no reason to show the failure of a canceled session: the person has already closed it, but
        // the message would fall on top of the one that is going now.
        guard isCurrent(session), !cancellationRequested else { return }

        let notice = DictationNotice(kind: .failure, message: error.userMessage)
        await report(notice, session: session)
        await cleanup(session: session)
    }

    private func finishWithoutInsertion(session: DictationSessionID) async {
        await cleanup(session: session)
    }

    /// Cleaning after the session is in strict order.
    ///
    /// The microphone is muted here and only here: the promise “the recording indicator is not
    /// lit while we are not listening" relies on the fact that this method is called
    /// on each completion path, including errors and cancellation.
    ///
    /// You can only clean up your own session: the tail of the previous one,
    /// woke up after cancellation, otherwise he would have extinguished the new one already in progress.
    private func cleanup(session: DictationSessionID) async {
        guard isCurrent(session) else { return }

        // Issue the terminal HUD command while N is still current, then make
        // its identity terminal before publishing any externally observable
        // idle state. An idle observer is allowed to start N+1 synchronously.
        dismissOverlay(session: session)
        // User cancellation already changed both dispositions synchronously in
        // `cancel()`. Technical containment also sets `cancellationRequested`
        // to stop recognition, but it must keep the raw take; never infer file
        // deletion from this transient control-flow flag.
        activeRecoveryTickets[session] = nil
        preparingStopWatchdog?.cancel()
        preparingStopWatchdog = nil
        currentSession = nil
        currentDisposition = nil
        finalizationTask = nil
        deferredStopRequested = false
        cancellationRequested = false
        isHandsFree = false
        isHandsFreeActive = false
        targetApplication = nil
        recordingStartedAt = nil
        activeRecordingURL = nil
        // The release mark is reset along with the rest of the session state.
        // Otherwise, t0 of the canceled dictation would flow into the next one, and it would report
        // would be about time, including someone else's waiting.
        stopRequestedAt = nil
        stopSLORequestedAt = nil
        // The next session starts able to sound again.
        hasSoundedThisSession = false
        state = .idle
    }

    private func elapsedSeconds() -> TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return now().timeIntervalSince(recordingStartedAt)
    }

    private func remainingBudget(
        until deadline: ContinuousClock.Instant,
        stageMaximum: Duration
    ) throws -> Duration {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw TranscriptionTimeout(deadline: .zero) }
        return min(remaining, stageMaximum)
    }

    /// Show the message: both to the subscriber and on the panel.
    ///
    /// The only way messages exit from the kernel — the attention sound
    /// rides on it, so a path around `report` is a path around the ear.
    @discardableResult
    private func report(
        _ notice: DictationNotice,
        session: DictationSessionID,
        allowCancellation: Bool = false
    ) async -> Bool {
        guard isCurrent(session), allowCancellation || !cancellationRequested else { return false }
        onNotice?(notice)
        guard isCurrent(session), allowCancellation || !cancellationRequested else { return false }
        playAttentionOnce(for: notice, session: session, allowCancellation: allowCancellation)
        presentNotice(notice, session: session)
        return true
    }

    /// One sound per session, and only for words that never landed.
    ///
    /// "The text was inserted, but Return failed" is shown, not sounded:
    /// the words are in the field, the person is looking at them. The ear is
    /// reserved for the loss they would otherwise miss.
    private func playAttentionOnce(
        for notice: DictationNotice,
        session: DictationSessionID,
        allowCancellation: Bool
    ) {
        guard isCurrent(session), allowCancellation || !cancellationRequested else { return }
        guard notice.wordsDidNotLand, !hasSoundedThisSession else { return }
        hasSoundedThisSession = true
        soundDispatcher.submit(session: session)
    }

    /// UI work never owns capture, recognition, or cleanup latency. Production
    /// overlay methods apply the session token at the MainActor mutation point,
    /// so a cancellation-deaf old command cannot overwrite a newer session.
    private func presentOverlay(
        _ state: DictationState,
        elapsed: TimeInterval,
        session: DictationSessionID
    ) {
        guard let revision = nextOverlayRevision(session: session) else { return }
        overlayDispatcher.submit(.present(state, elapsed, session, revision))
    }

    private func dismissOverlay(session: DictationSessionID) {
        guard let revision = nextOverlayRevision(session: session) else { return }
        overlayDispatcher.submit(.dismiss(session, revision))
    }

    private func presentNotice(_ notice: DictationNotice, session: DictationSessionID) {
        guard let revision = nextOverlayRevision(session: session) else { return }
        overlayDispatcher.submit(.notice(notice, session, revision))
    }

    private func nextOverlayRevision(session: DictationSessionID) -> UInt64? {
        guard isCurrent(session) else { return nil }
        precondition(overlayRevision < UInt64.max, "overlay revision exhausted")
        overlayRevision += 1
        return overlayRevision
    }

    /// Remove a record from disk.
    ///
    /// A separate method so that deletion cannot be accidentally missed on
    /// one of the completion branches: the user's voice should not remain in
    /// files after the text is recognized.
    private func discard(_ url: URL, session _: DictationSessionID? = nil) async {
        RecordingFileDisposer.shared.submit(url)
    }

    private static func positiveDifference(
        later: Duration?,
        earlier: Duration?
    ) -> Duration? {
        guard let later, let earlier else { return nil }
        let difference = later - earlier
        return difference >= .zero ? difference : nil
    }

}

/// Errors that the user sees.
///
/// Insertion failure is not included here intentionally: the text at this moment is already recognized and
/// remains in memory, and the person should be told not “failed”, but how to get
/// it via Copy/Retry. This does `handleInsertionFailure`.
public enum DictationError: Error, Sendable, Equatable {
    case capture(String)
    case recognition(String)

    public var userMessage: String {
        switch self {
        case .capture:
            return "Couldn't record audio."
        case .recognition:
            return "Couldn't transcribe speech."
        }
    }
}

private enum RecordingFinalizationStage: Sendable, Equatable {
    case freeze
    case readableFile
}

private struct RecordingFinalizationTimeout: Error, Sendable, Equatable {
    let stage: RecordingFinalizationStage
}

/// Carries one measured duration out of an escaping closure.
///
/// The readable wait is taken inside the deadline wrapper, and the report is
/// built outside it. A reference is the smallest way across that boundary.
final class MeasurementBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

typealias DurationBox = MeasurementBox<Duration>
