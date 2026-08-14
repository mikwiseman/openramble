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
    /// How long did the recognition itself take - for measurements and for display in diagnostics.
    public let processingDuration: TimeInterval
    /// Benchmark-only phase measurements. Production engines leave this `nil`.
    public let phaseTimings: ASRPhaseTimings?

    public init(
        text: String,
        words: [Word] = [],
        audioDuration: TimeInterval,
        processingDuration: TimeInterval,
        phaseTimings: ASRPhaseTimings? = nil
    ) {
        self.text = text
        self.words = words
        self.audioDuration = audioDuration
        self.processingDuration = processingDuration
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
/// The only implementation in the project is `FluidAudioAdapter` in the LocalASR package,
/// and this is the only place where FluidAudio is imported. Everything else - including
/// tests of pure logic - works through this protocol and uses a mock.
public protocol ASREngineAdapting: Sendable {
    /// Load the model from the prepared directory. Idempotent.
    func loadModels(from directory: URL) async throws

    /// Recognize the fragment. Mono 16 kHz Float32 is expected - exactly what the capture gives.
    func transcribe(samples: [Float]) async throws -> ASRResult

    /// Recognize with language hint.
    ///
    /// `languageHint` - BCP-47 code (“en”, “ru”). `nil` — autodetection by
    /// sound. The hint narrows the recognition to one language: this is the way out for
    /// cases when the accent leads the autodetection to the wrong place, but mixed speech
    /// it breaks - that's why the default is always `nil`.
    func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult

    /// Free up memory under the model.
    func unload() async
}

extension ASREngineAdapting {
    /// Hint - an optional ability of the engine: for those who don’t understand it,
    /// recognizes as usual. This is a hint contract, not a degradation.
    public func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult {
        try await transcribe(samples: samples)
    }
}
