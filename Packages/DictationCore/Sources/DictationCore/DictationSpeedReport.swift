import Foundation

/// How long it took from releasing the key to each noticeable point.
///
/// There are three marks, not one, because “fast” are three different promises, and
/// it’s unfair to confuse them:
///
/// - `toRecognizedText` - the engine returned the text;
/// - `toPasteDispatched` - ⌘V sent, that is, the text is already in someone else’s window.
/// **This is the headline metric** and what the HUD shows;
/// - `toClipboardRestored` - the previous contents of the buffer are returned to their place.
///
/// There is no prohibited metric here intentionally: “time until return
/// `TextInserter.insert`" is not a speed - it’s a thousand milliseconds inside
/// buffer protection. It's waiting, not working.
///
/// `nil` means "not measured", and never "zero". The land that can't
/// give a mark, has no right to look instant.
public struct DictationSpeedReport: Sendable, Equatable {
    public let toRecognizedText: Duration
    public let toPasteDispatched: Duration?
    public let toClipboardRestored: Duration?
    /// How long the microphone was raised before the first frame. Does not count from
    /// releases are a warm-up before the phrase, not after it.
    public let microphoneStartup: Duration?
    /// Where `toRecognizedText` actually went. `nil` only for a report built
    /// without the breakdown; a stage that did not run is absent inside it.
    public let phases: DictationPhaseBreakdown?

    public init(
        toRecognizedText: Duration,
        toPasteDispatched: Duration? = nil,
        toClipboardRestored: Duration? = nil,
        microphoneStartup: Duration? = nil,
        phases: DictationPhaseBreakdown? = nil
    ) {
        self.toRecognizedText = toRecognizedText
        self.toPasteDispatched = toPasteDispatched
        self.toClipboardRestored = toClipboardRestored
        self.microphoneStartup = microphoneStartup
        self.phases = phases
    }
}

/// Which causal stage of a finished take owned the wait.
///
/// A single "stop → text" number cannot tell a slow engine from a model that
/// was not resident, and it cannot tell either of them from a machine that
/// paged the engine out between two takes. Those are different bugs with
/// different fixes, so the stages are measured apart.
///
/// The first three are consecutive and sum to `toRecognizedText`.
/// `engineProcessing` is not one of them: it is the same interval as
/// `recognition` seen from inside the engine, so `recognition` minus
/// `engineProcessing` is everything recognition costs that is not recognition —
/// transport, scheduling, and page faults.
///
/// A stage that did not run is `nil` and never zero. Zero is a measurement.
public struct DictationPhaseBreakdown: Sendable, Equatable {
    /// Key-up → the capture handed its PCM over.
    public let captureFreeze: Duration
    /// The foreground wait for a model that was not resident when the person
    /// stopped speaking. `nil` when this build has no preparation hook at all;
    /// a near-zero value means the engine was already there.
    public let enginePreparation: Duration?
    /// The recognition call as the application measured it, transport included.
    public let recognition: Duration
    /// The same call as the engine reported it, transport excluded.
    public let engineProcessing: Duration?
    /// How long the take waited before the engine started on it.
    ///
    /// The stage that was missing. `recognition` minus `engineProcessing` used
    /// to be a single unattributed lump, and every stall this app has had lived
    /// inside it — a blocked thread pool, a doubled inference, a disk. Naming
    /// it means the next one identifies itself instead of needing a sampler.
    public let engineQueueing: Duration?
    /// Opening and decoding the recording, which is where an eleven-second
    /// dictation with a tenth of a second of inference actually went.
    public let audioDecoding: Duration?
    /// Waiting for the recording to finish being written and closed.
    ///
    /// The last span on the path with no number. It sits between the
    /// microphone stopping and the engine being called, and it is where the
    /// time was: the recording has to be drained and sealed before anything
    /// can read it, and that is disk work.
    public let recordingReadable: Duration?
    /// Everything between dispatching the recognition call and the engine
    /// starting work — executor hops, actor entry, waiting for a thread.
    ///
    /// The span that held every slow take. It had no number because every
    /// earlier stamp was placed past it, inside the actor it was waiting to
    /// enter.
    public let engineTransport: Duration?
    /// The hop off the main actor alone, separated from the rest of transport.
    ///
    /// `engineTransport` covers both leaving the main actor and reaching the
    /// engine. The two have different remedies — one is a main-actor binding,
    /// the other a blocked pool — so they are measured apart before either is
    /// acted on.
    public let executorHandover: Duration?
    /// Resume work performed by the generic executor after recognition ended.
    public let poolReturn: Duration?
    /// The final hop from the generic executor back to the main actor.
    public let mainActorReturn: Duration?
    /// Admission to and return from the engine's own serial execution queue.
    public let engineDispatch: Duration?
    /// Runtime witness for the frame that stamped `poolReturn`.
    /// `mainActorReturn` is trustworthy only when this is `false`.
    public let returnFrameWasMainThread: Bool?
    /// How much audio the take actually carried.
    public let audioDuration: Duration
    /// How many pieces were recognized while the person was still speaking.
    ///
    /// Zero means the take went to the engine whole, which is what a short one
    /// does and what any take with no pause in it does. Without this number the
    /// log cannot tell a fast take from a streamed one, and those want
    /// different explanations.
    public let streamedSegments: Int

    public init(
        captureFreeze: Duration,
        enginePreparation: Duration?,
        recognition: Duration,
        engineProcessing: Duration?,
        engineQueueing: Duration? = nil,
        audioDecoding: Duration? = nil,
        recordingReadable: Duration? = nil,
        executorHandover: Duration? = nil,
        poolReturn: Duration? = nil,
        mainActorReturn: Duration? = nil,
        engineDispatch: Duration? = nil,
        returnFrameWasMainThread: Bool? = nil,
        engineTransport: Duration? = nil,
        audioDuration: Duration,
        streamedSegments: Int = 0
    ) {
        self.captureFreeze = captureFreeze
        self.enginePreparation = enginePreparation
        self.recognition = recognition
        self.engineProcessing = engineProcessing
        self.engineQueueing = engineQueueing
        self.audioDecoding = audioDecoding
        self.recordingReadable = recordingReadable
        self.engineTransport = engineTransport
        self.executorHandover = executorHandover
        self.poolReturn = poolReturn
        self.mainActorReturn = mainActorReturn
        self.engineDispatch = engineDispatch
        self.returnFrameWasMainThread = returnFrameWasMainThread
        self.audioDuration = audioDuration
        self.streamedSegments = streamedSegments
    }
}

/// When the insertion has done something that is visible to humans.
///
/// The inserter himself removes the marks: they cannot be taken from outside, because `insert`
/// returns only after a second of buffer protection.
public struct InsertionMarks: Sendable, Equatable {
    public let pasteDispatchedAt: ContinuousClock.Instant?
    public let clipboardRestoredAt: ContinuousClock.Instant?

    public init(
        pasteDispatchedAt: ContinuousClock.Instant? = nil,
        clipboardRestoredAt: ContinuousClock.Instant? = nil
    ) {
        self.pasteDispatchedAt = pasteDispatchedAt
        self.clipboardRestoredAt = clipboardRestoredAt
    }
}
