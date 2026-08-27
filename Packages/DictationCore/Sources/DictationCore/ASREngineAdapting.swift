import Foundation

/// Opt-in phase timings for one recognition result.
///
/// These values deliberately travel with the result instead of living in mutable
/// engine state: a cancelled or overlapping request can never attach its timings
/// to another transcript. Phase durations may overlap when the reference CTC
/// scheduler runs alongside the primary recognizer.
public struct ASRPhaseTimings: Sendable, Equatable {
    public enum VocabularyOutcome: String, Sendable, Equatable {
        case notConfigured = "not_configured"
        case noCandidate = "no_candidate"
        case candidateNoUsableEvidence = "candidate_no_usable_evidence"
        case rescoredUnmodified = "rescored_unmodified"
        case rescoredModified = "rescored_modified"
    }

    public let primaryTDTInferenceDecodeNanoseconds: UInt64
    public let lexicalCandidateGateNanoseconds: UInt64?
    public let ctcModelInferenceNanoseconds: UInt64?
    public let ctcRescoringFusionNanoseconds: UInt64?
    public let ctcInferenceInvocations: Int
    public let vocabularyOutcome: VocabularyOutcome
    public let phasesMayOverlap: Bool

    public init(
        primaryTDTInferenceDecodeNanoseconds: UInt64,
        lexicalCandidateGateNanoseconds: UInt64?,
        ctcModelInferenceNanoseconds: UInt64?,
        ctcRescoringFusionNanoseconds: UInt64?,
        ctcInferenceInvocations: Int,
        vocabularyOutcome: VocabularyOutcome,
        phasesMayOverlap: Bool
    ) {
        self.primaryTDTInferenceDecodeNanoseconds = primaryTDTInferenceDecodeNanoseconds
        self.lexicalCandidateGateNanoseconds = lexicalCandidateGateNanoseconds
        self.ctcModelInferenceNanoseconds = ctcModelInferenceNanoseconds
        self.ctcRescoringFusionNanoseconds = ctcRescoringFusionNanoseconds
        self.ctcInferenceInvocations = ctcInferenceInvocations
        self.vocabularyOutcome = vocabularyOutcome
        self.phasesMayOverlap = phasesMayOverlap
    }
}

/// The result of recognizing one fragment of speech.
///
/// The type is declared here, and not in LocalASR, intentionally: pure logic should be able to
/// work with the result without knowing anything about which engine produced it.
public struct ASRResult: Sendable, Equatable {
    /// One word with time boundaries relative to the beginning of the fragment.
    public struct Word: Sendable, Equatable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval
        public let confidence: Double?

        public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
        }
    }

    /// The finished text without post-processing is exactly what the engine heard.
    public let text: String
    /// Word-by-word timings. An empty array is acceptable: not every engine provides them.
    public let words: [Word]
    /// Duration of recognized audio.
    public let audioDuration: TimeInterval
    /// Wall time spent inside the engine runtime call itself.
    public let processingDuration: TimeInterval
    /// Time around the runtime call: admission to the engine's execution
    /// queue plus the continuation's return to its owner.
    public let engineDispatchDuration: TimeInterval
    /// How long the call waited before the engine began.
    ///
    /// This is the wait outside the engine's own execution queue: actor
    /// admission, warm-up ownership and another dictation holding the actor.
    /// `engineDispatchDuration` accounts for the queue immediately around the
    /// runtime call, so the two must remain separate.
    public let queueingDuration: TimeInterval
    /// How long opening and decoding the recording took.
    ///
    /// Split out from the wait because it is the part that turned out to
    /// matter, and because a lump that says "something before the engine" is
    /// what let this hide for months.
    public let decodingDuration: TimeInterval
    /// Benchmark-only phase measurements. Production engines leave this `nil`.
    public let phaseTimings: ASRPhaseTimings?

    public init(
        text: String,
        words: [Word] = [],
        audioDuration: TimeInterval,
        processingDuration: TimeInterval,
        engineDispatchDuration: TimeInterval = 0,
        queueingDuration: TimeInterval = 0,
        decodingDuration: TimeInterval = 0,
        phaseTimings: ASRPhaseTimings? = nil
    ) {
        self.text = text
        self.words = words
        self.audioDuration = audioDuration
        self.processingDuration = processingDuration
        self.engineDispatchDuration = engineDispatchDuration
        self.queueingDuration = queueingDuration
        self.decodingDuration = decodingDuration
        self.phaseTimings = phaseTimings
    }
}

/// Recognition engine errors.
///
/// Not a single case is silent: each branch must reach the user.
public enum ASREngineError: Error, Sendable, Equatable {
    /// The model is not loaded - calling `transcribe` without `prepare`.
    case modelsNotLoaded
    /// Model files are missing or damaged.
    case modelsUnavailable(String)
    /// Audio is not in the format expected by the engine.
    case unsupportedAudioFormat(String)
    /// The engine worked, but fell inside.
    case inferenceFailed(String)
    /// Recognition has been canceled by the user.
    case cancelled
}

/// Recognition engine contract.
///
/// The only implementation in the project is `TranscribeCppAdapter` in the
/// LocalASR package, and that is the only place the inference runtime is
/// imported. Everything else - including tests of pure logic - works through
/// this protocol and uses a mock.
///
/// There is no language parameter here, and the absence is a measurement
/// rather than an oversight: the shipping engine decides the language from the
/// audio and cannot be told otherwise. `TranscribeCppAdapter.transcribe(samples:)`
/// carries the numbers.
public protocol ASREngineAdapting: Sendable {
    /// Load the model from the prepared directory. Idempotent.
    func loadModels(from directory: URL) async throws

    /// Recognize the fragment. Mono 16 kHz Float32 is expected - exactly what the capture gives.
    func transcribe(samples: [Float]) async throws -> ASRResult

    /// Free up memory under the model.
    func unload() async
}
