import Foundation

/// What to do with recognized text if it was not possible to insert it.
public struct RecoveredDictation: Sendable, Equatable {
    public let text: String
}

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
    private let inserter: any TextInserting
    private let overlay: any OverlayPresenting
    private let sounds: any Sounding
    private let recordingRecovery: any RecordingRecoveryStoring
    private let pipeline: () -> TextPipeline
    /// Session hours. A separate dependence for exactly the same reason as
    /// microphone: hour limit otherwise cannot be checked without waiting an hour.
    private let now: @Sendable () -> Date
    /// The monotonous clock is separate from the wall clock, and this is not duplication.
    ///
    /// `now` is responsible for the hour limit, which is the idea of wall time.
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
    private var recordingStartedAt: Date?
    /// The moment the key is released is the start of the “stop → text” countdown.
    private var stopRequestedAt: ContinuousClock.Instant?

    /// The number of the current session increases at each start.
    ///
    /// Cancellation does not interrupt an already started wait, but only marks it:
    /// recognition finishes reading its buffer and wakes up later - when the person
    /// managed to start the next dictation. Without a number, such a tail brought cleaning to a
    /// end and extinguished ANOTHER'S live session: the state showed “free”, and
    /// the microphone remained on, and there was nothing to get out of it.
    private var currentSession = 0

    /// A message that waits for the end of the session.
    ///
    /// Cannot be shown immediately: after stopping, the panel is redrawn under
    /// “recognizes” and erases the message - it lives on the screen for a split second.
    /// While waiting only for an explanation of the hour limit: the only way where
    /// it is not a person or a glitch that ends the session.
    private var noticeAfterSession: DictationNotice?
    /// Whether this session has already asked for the person's attention.
    private var hasSoundedThisSession = false

    public init(
        capture: any AudioCapturing,
        transcribe: @escaping @Sendable (URL) async throws -> ASRResult,
        inserter: any TextInserting,
        overlay: any OverlayPresenting,
        sounds: any Sounding,
        recordingRecovery: any RecordingRecoveryStoring = DiscardingRecordingRecovery(),
        pipeline: @escaping () -> TextPipeline = { TextPipeline() },
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        transcriptionDeadline: @escaping @Sendable (TimeInterval) -> Duration = TranscriptionDeadline.deadline(forAudioDuration:),
        prepareForTranscription: (@Sendable () async throws -> Void)? = nil,
        prepareDeadline: Duration = .seconds(90)
    ) {
        self.capture = capture
        self.transcribe = transcribe
        self.inserter = inserter
        self.overlay = overlay
        self.sounds = sounds
        self.recordingRecovery = recordingRecovery
        self.pipeline = pipeline
        self.now = now
        self.monotonicNow = monotonicNow
        self.transcriptionDeadline = transcriptionDeadline
        self.prepareForTranscription = prepareForTranscription
        self.prepareDeadline = prepareDeadline
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

        currentSession += 1
        let session = currentSession
        // Do not touch the previous Copy/Retry: the new entry can be canceled or
        // fail with an error. Saved text is deleted only by an explicit action
        // or after a successful Retry.
        isHandsFree = handsFree
        isHandsFreeActive = handsFree
        cancellationRequested = false
        deferredStopRequested = false
        noticeAfterSession = nil
        // We remember the goal right away: then the focus will go away.
        targetApplication = inserter.frontmostApplication()
        state = .preparing

        Task {
            // A capture device can take a noticeable fraction of a second to wake up.
            // Acknowledge the hotkey before that wait so the gesture never feels lost.
            await overlay.present(.preparing, elapsed: 0)
            await startCapture(session: session)
        }
    }

    private func startCapture(session: Int) async {
        // Second check of the same condition: between the synchronous part and this
        // the line passed a transition between tasks, during which the session could be cancelled.
        guard isCurrent(session), state == .preparing, !cancellationRequested else {
            await finishWithoutInsertion(session: session)
            return
        }

        do {
            _ = try await capture.startRecording()
        } catch {
            await fail(session: session, with: .capture(String(describing: error)))
            return
        }

        // After waiting, the status is checked again - the cancellation could have come
        // exactly at the moment the engine starts.
        guard isCurrent(session), state == .preparing, !cancellationRequested else {
            // The recording has started, but the session is no longer there. We turn off our microphone -
            // otherwise it will remain on, and there will be nothing to stop it, -
            // but we don’t do the cleaning: it belongs to the session that is going on now.
            await capture.abortRecording()
            await finishWithoutInsertion(session: session)
            return
        }

        recordingStartedAt = now()
        state = .listening
        await overlay.present(.listening, elapsed: 0)

        // The release that came while the engine was rising is processed here -
        // exactly once. Before the signal is intentional: wait for the first frame for the sake of
        // there is no need for the “say” sound in a recording that has already ended, but
        // delaying the stop due to waiting would mean holding the microphone
        // turned on on a silent device until the frame arrives, and it
        // may not arrive at all.
        if deferredStopRequested {
            deferredStopRequested = false
            finish()
            return
        }

        // The first frame is still awaited — the panel promises "speak" only
        // once the microphone is really sending sound — but nothing is played
        // here any more. The panel is the signal; see `Sounding`.
        _ = await capture.waitForFirstFrame()
    }

    // MARK: - Stop

    /// The hotkey is released (or pressed a second time in hands-free mode).
    public func stop() {
        switch DictationStopPolicy.decideStop(state: state, isHandsFree: isHandsFree) {
        case .stopNow:
            finish()
        case .deferUntilListening:
            deferredStopRequested = true
        case .ignore, .noSession:
            break
        }
    }

    /// Stop in the mode without holding - by pressing the key a second time.
    public func stopHandsFree() {
        guard isHandsFree else { return }

        switch state {
        case .listening:
            finish()
        case .preparing:
            // Same as releasing the key, only pressing: second
            // the press arrived before the engine rose. Lose it
            // not allowed - in this mode the key is not held down and the recording is stopped
            // nothing more: the microphone would work up to the hour limit.
            deferredStopRequested = true
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
        isHandsFree = true
        isHandsFreeActive = true
        deferredStopRequested = false
    }

    private func finish() {
        // Finalization runs exactly once: otherwise the text will be inserted twice.
        guard finalizationTask == nil, state == .listening else { return }

        // One input for all four stop paths: stop, stopHandsFree,
        // delayed release and hour limit - everyone comes here.
        stopRequestedAt = monotonicNow()
        let session = currentSession
        state = .transcribing
        let task = Task { [weak self] in
            await self?.finalize(session: session)
            await MainActor.run { self?.forgetFinalization(session: session) }
        }
        finalizationTask = task
    }

    /// Forget the completed task - but only if it is still our session.
    private func forgetFinalization(session: Int) {
        guard isCurrent(session) else { return }
        finalizationTask = nil
    }

    /// Move the take into safekeeping and word the outcome for the notice.
    private func preserveForRetry(_ url: URL) async -> (saved: URL?, suffix: String) {
        do {
            let saved = try await recordingRecovery.preserve(url)
            return (
                saved,
                saved == nil
                    ? " The recording couldn't be kept."
                    : " The recording is kept on this Mac for a few days"
                        + " (Settings → About → Reveal Support Folder)."
            )
        } catch {
            return (nil, " The recording is still on disk, but safekeeping failed: \(error.localizedDescription)")
        }
    }

    private func finalize(session: Int) async {
        await overlay.present(.transcribing, elapsed: elapsedSeconds())

        let recording: (url: URL, duration: TimeInterval)
        do {
            recording = try await capture.stopRecording()
        } catch {
            await fail(session: session, with: .capture(String(describing: error)))
            return
        }

        guard shouldContinue(session) else {
            await discard(recording.url)
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
            await discard(recording.url)
            switch outcome {
            case .dropSilently:
                await finishWithoutInsertion(session: session)
            case .reportSilentInput:
                let notice = DictationNotice(
                    kind: .failure,
                    message: "The microphone recorded nothing — check that the right input device is selected and not muted."
                )
                await report(notice)
                await cleanup(session: session)
            }
            return
        }

        let recognized: ASRResult
        do {
            // A residency-managed engine may be cold here; the reload has
            // been running under the person's voice since the keypress and
            // gets its own budget. Only after the engine is in memory does
            // the recognition deadline start counting.
            if let prepareForTranscription {
                try await withTranscriptionDeadline(prepareDeadline) {
                    try await prepareForTranscription()
                }
            }
            // The deadline stands between the person and a wedged engine: a
            // CoreML prediction stuck on a dead system service ignores
            // cancellation and would hold "Transcribing…" forever.
            recognized = try await withTranscriptionDeadline(
                transcriptionDeadline(recording.duration)
            ) { [transcribe] in
                try await transcribe(recording.url)
            }
        } catch is CancellationError {
            await discard(recording.url)
            await finishWithoutInsertion(session: session)
            return
        } catch let error as ASREngineError where error == .cancelled {
            // Cancellation received through the engine: this is not a failure, nothing to report.
            await discard(recording.url)
            await finishWithoutInsertion(session: session)
            return
        } catch is TranscriptionTimeout {
            guard shouldContinue(session) else {
                await discard(recording.url)
                await finishWithoutInsertion(session: session)
                return
            }
            let (saved, suffix) = await preserveForRetry(recording.url)
            let notice = DictationNotice(
                kind: .failure,
                message: "Transcribing took too long and was stopped." + suffix,
                recoveryAudio: saved
            )
            await report(notice)
            // After the report, so the owner recycles a quiet engine, not one
            // still being blamed for the current session.
            onTranscriptionStall?()
            await cleanup(session: session)
            return
        } catch {
            // A cancellation that came while the engine was running is more important than its failure. Otherwise
            // Escape would leave exactly the trace it gets rid of:
            // the voice and failure message saved for Retry are already on top of that one
            // the session that the person started next.
            guard shouldContinue(session) else {
                await discard(recording.url)
                await finishWithoutInsertion(session: session)
                return
            }
            let (saved, suffix) = await preserveForRetry(recording.url)
            let notice = DictationNotice(
                kind: .failure,
                message: DictationError.recognition(String(describing: error)).userMessage + suffix,
                recoveryAudio: saved
            )
            await report(notice)
            await cleanup(session: session)
            return
        }

        // Check after each wait: while recognition was in progress, the user
        //could press cancel.
        guard shouldContinue(session) else {
            await discard(recording.url)
            await finishWithoutInsertion(session: session)
            return
        }

        // t1: the engine returned the text. Removed before all checks below, so that
        // the number did not hit our own branch.
        let recognizedAt = monotonicNow()
        let microphoneStartup = await capture.startupLatency()

        let run = pipeline().run(recognized.text)
        let processed = run.output
        guard !processed.text.isEmpty else {
            // An empty result is not an error: the person could remain silent, speak
            // too quiet or using the wrong microphone. But one cannot remain silent in response:
            // a blank panel without text is indistinguishable from “inserted in the wrong place”, and
            // a person goes to look for the missing phrase in someone else's window. Too
            // short press does not go here - it is filtered out above and explanations
            // not required.
            await discard(recording.url)
            let notice = DictationNotice(
                kind: .info,
                message: "Nothing was recognized — nothing was inserted."
            )
            await report(notice)
            await cleanup(session: session)
            return
        }

        await insert(
            processed,
            provenance: run.provenance,
            recognizedAt: recognizedAt,
            microphoneStartup: microphoneStartup,
            session: session
        )
        await discard(recording.url)
    }

    /// Collect a speed report and send it outside.
    ///
    /// Without the release mark, there is no report at all: counting “stop → text” is not from
    /// what, but to show a number calculated from something else is to lie.
    private func reportSpeed(
        recognizedAt: ContinuousClock.Instant,
        marks: InsertionMarks,
        microphoneStartup: Duration?
    ) {
        guard let onSpeed, let stopRequestedAt else { return }
        onSpeed(
            DictationSpeedReport(
                toRecognizedText: stopRequestedAt.duration(to: recognizedAt),
                toPasteDispatched: marks.pasteDispatchedAt.map { stopRequestedAt.duration(to: $0) },
                toClipboardRestored: marks.clipboardRestoredAt.map { stopRequestedAt.duration(to: $0) },
                microphoneStartup: microphoneStartup
            )
        )
    }

    private func insert(
        _ output: TextPipeline.Output,
        provenance: PipelineProvenance,
        recognizedAt: ContinuousClock.Instant,
        microphoneStartup: Duration?,
        session: Int
    ) async {
        state = .inserting
        // Cmd+V is the meaningful completion feedback. Do not leave a redundant
        // “Inserting” panel over the destination application while the clipboard is
        // restored in the background.
        await overlay.dismiss()

        // Last point where cancellation is still possible. Then the event goes into
        // someone else's application and does not respond.
        guard shouldContinue(session) else {
            await finishWithoutInsertion(session: session)
            return
        }

        let marks: InsertionMarks
        do {
            marks = try await inserter.insertReportingMarks(output.text, into: targetApplication)
        } catch {
            await handleInsertionFailure(error, text: output.text, session: session)
            return
        }
        onTextInserted?(output.text)
        // Origin - only after a successful insertion: unsuccessful insertion does not
        // “what the person saw” and “copy verbatim” she has nothing to give.
        onDictationCompleted?(provenance)
        reportSpeed(recognizedAt: recognizedAt, marks: marks, microphoneStartup: microphoneStartup)

        // The click is parsed separately from the insertion intentionally. These are different
        // system calls, and the second one fails when the first one is alive - for example,
        // when the user never released the modifier.
        if output.command == .pressReturn {
            do {
                try await inserter.pressReturn()
            } catch {
                await reportReturnFailure(session: session)
                return
            }
        }
        await cleanup(session: session)
    }

    /// The text was inserted, but pressing Return failed.
    ///
    /// The general denial thread would lie twice here: it would say “the text is not
    /// inserted" when it is in place, and would save a second copy of the dictated
    /// to disk. The private tool does not add up what is said without reason.
    private func reportReturnFailure(session: Int) async {
        let notice = DictationNotice(
            kind: .warning,
            message: "The text was inserted, but pressing Return failed."
        )
        await report(notice)
        await cleanup(session: session)
    }

    /// The text was recognized, but it was not possible to insert it - we save it so that it does not disappear.
    private func handleInsertionFailure(_ error: Error, text: String, session: Int) async {
        if let insertion = error as? TextInsertionError,
           insertion == .insertedButClipboardRestoreFailed {
            let notice = DictationNotice(
                kind: .warning,
                message: "The text was inserted, but the previous clipboard couldn't be restored."
            )
            await report(notice)
            await cleanup(session: session)
            return
        }
        pendingRecovery = RecoveredDictation(text: text)

        let message: String
        if let insertion = error as? TextInsertionError, insertion == .secureInputActive {
            // Not a failure, but a normal situation: the password field is active.
            message = "Text not inserted: secure input is active. Your text is saved in the menu."
        } else {
            message = "The text couldn't be inserted. It's saved in the menu."
        }

        let notice = DictationNotice(kind: .warning, message: message, recoverableText: text)
        await report(notice)
        await cleanup(session: session)
    }

    // MARK: - Cancel

    /// Cancel dictation.
    public func cancel() {
        guard DictationStopPolicy.canCancel(state: state) else { return }

        // The order is important: first the flag, then cancel the task. Canceling a task does not
        // interrupts an already ongoing wait, and the flag is checked after each of them.
        cancellationRequested = true
        finalizationTask?.cancel()

        let session = currentSession
        Task { [weak self] in
            await self?.capture.abortRecording()
            await self?.finishWithoutInsertion(session: session)
        }
    }

    /// The recording failed on its own - for example, the disk ran out of space.
    ///
    /// This is not a cancellation: the user did not click anything and continues to talk.
    /// Therefore, we stop immediately and explain the reason, and do not wait until he
    /// finishes a phrase that there is nowhere to write down.
    public func interrupt(reason message: String) {
        guard state == .preparing || state == .listening else { return }

        cancellationRequested = true
        finalizationTask?.cancel()

        let notice = DictationNotice(kind: .failure, message: message)
        noticeAfterSession = nil
        onNotice?(notice)

        let session = currentSession
        Task { [weak self] in
            guard let self else { return }
            await self.overlay.presentNotice(notice)
            await self.capture.abortRecording()
            await self.finishWithoutInsertion(session: session)
        }
    }

    /// System permission or device disappeared while recording.
    /// Close the WAV and save it for an explicit Retry/Delete without trying
    /// recognize or insert into an already untrusted system state.
    public func preserveActiveRecording(reason message: String) {
        guard state == .preparing || state == .listening else { return }
        if state == .preparing {
            cancel()
            let notice = DictationNotice(kind: .failure, message: message)
            noticeAfterSession = nil
            onNotice?(notice)
            Task { await overlay.presentNotice(notice) }
            return
        }
        guard finalizationTask == nil else { return }

        let session = currentSession
        state = .transcribing
        let task = Task { [weak self] in
            guard let self else { return }
            let recording: (url: URL, duration: TimeInterval)?
            do {
                recording = try await self.capture.stopRecording()
            } catch {
                recording = nil
            }

            // While the file was closing, the person could press Escape. From now on
            // dictation has one outcome - cancellation, and it is more important than salvation: closed
            // WAV will no longer delete the recording interruption, and the saved one would go into the folder
            // repeat contrary to the promise “the canceled dictation is deleted.” At the same time
            // keep quiet: the failure message would fall on top of the session that
            // the man started next.
            guard !Task.isCancelled else {
                if let recording { await self.discard(recording.url) }
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
                await self.discard(recording.url)
                notice = DictationNotice(kind: .failure, message: message)
            } else {
                var saved: URL?
                if let recording {
                    saved = try? await self.recordingRecovery.preserve(recording.url)
                }
                notice = DictationNotice(
                    kind: .failure,
                    message: saved == nil
                        ? message + " The recording couldn't be kept."
                        : message + " The recording is kept on this Mac for a few days"
                            + " (Settings → About → Reveal Support Folder).",
                    recoveryAudio: saved
                )
            }
            await self.report(notice)
            await self.cleanup(session: session)
        }
        finalizationTask = task
    }

    // MARK: - Completion

    /// Is the session for which the wait began still ongoing?
    private func isCurrent(_ session: Int) -> Bool { session == currentSession }

    private func shouldContinue(_ session: Int) -> Bool {
        guard isCurrent(session) else { return false }
        return DictationFinalizationPolicy.shouldContinue(
            state: state,
            cancellationRequested: cancellationRequested,
            taskCancelled: Task.isCancelled
        )
    }

    private func fail(session: Int, with error: DictationError) async {
        // There is no reason to show the failure of a canceled session: the person has already closed it, but
        // the message would fall on top of the one that is going now.
        guard isCurrent(session) else { return }

        let notice = DictationNotice(kind: .failure, message: error.userMessage)
        await report(notice)
        await cleanup(session: session)
    }

    private func finishWithoutInsertion(session: Int) async {
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
    private func cleanup(session: Int) async {
        guard isCurrent(session) else { return }

        finalizationTask = nil
        deferredStopRequested = false
        cancellationRequested = false
        isHandsFree = false
        isHandsFreeActive = false
        targetApplication = nil
        recordingStartedAt = nil
        // The release mark is reset along with the rest of the session state.
        // Otherwise, t0 of the canceled dictation would flow into the next one, and it would report
        // would be about time, including someone else's waiting.
        stopRequestedAt = nil
        state = .idle

        // The deferred message is shown here - when the panel is already free.
        if let pending = noticeAfterSession {
            noticeAfterSession = nil
            onNotice?(pending)
            await playAttentionOnce()
            await overlay.presentNotice(pending)
        } else {
            await overlay.dismiss()
        }
        // The next session starts able to sound again.
        hasSoundedThisSession = false
    }

    private func elapsedSeconds() -> TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return now().timeIntervalSince(recordingStartedAt)
    }

    /// Show the message: both to the subscriber and on the panel.
    ///
    /// The only way messages exit from the kernel. Filmed here
    /// deferred: the session has one reason for ending, not two, and an explanation
    /// The hour limit has no right to erase the story of the failure.
    private func report(_ notice: DictationNotice) async {
        noticeAfterSession = nil
        onNotice?(notice)
        await playAttentionOnce()
        await overlay.presentNotice(notice)
    }

    /// One sound per session, however many notices the way out produces.
    ///
    /// The person needs to be told once that the panel wants them; a second
    /// chime for the same session is noise about a fact they already know.
    private func playAttentionOnce() async {
        guard !hasSoundedThisSession else { return }
        hasSoundedThisSession = true
        await sounds.playAttention()
    }

    /// Remove a record from disk.
    ///
    /// A separate method so that deletion cannot be accidentally missed on
    /// one of the completion branches: the user's voice should not remain in
    /// files after the text is recognized.
    private func discard(_ url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let notice = DictationNotice(
                kind: .failure,
                message: "Couldn't delete the local recording: \(error.localizedDescription)"
            )
            await report(notice)
        }
    }

    /// Whether the duration limit has been reached is checked by an external timer.
    public func checkDurationLimit() {
        guard state == .listening else { return }
        if DictationDurationPolicy.action(elapsed: elapsedSeconds()) == .stopAndTranscribe {
            // Cannot be shown now: `finish()` will immediately redraw the panel under
            // “I recognize.” But only through `onNotice` - that means nowhere: panel
            // does not show messages from the subscriber, and the explanation of the break is on
            // the half-sentence didn’t come through at all.
            noticeAfterSession = DictationNotice(
                kind: .info,
                message: "Reached the one-hour limit. Transcribing what was recorded."
            )
            finish()
        }
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
