import AVFAudio
import CoreML
import DictationCore
import FluidAudio
import Foundation

/// Which encoder file to load.
///
/// There are two of them in the model repository. Names are from library terms, not descriptions
/// quantization: `Encoder.mlmodelc` is quantized with a 6-bit palette (as specified
/// in CC BY attribution), `EncoderInt4.mlmodelc` - four-bit.
public enum EncoderVariant: String, Sendable, CaseIterable {
    case palettized6bit
    case int4
}

/// How to count the encoder.
///
/// The preprocessor library is always attached to the CPU, the decoder and joint go to
/// neuromodule. Only the encoder is configured - the hardest part.
/// Where CoreML may place the 425 MB encoder.
///
/// Shipping uses `.automatic`: it maps explicitly to Core ML `.all`, while the
/// persistent worker performs a real dummy inference before declaring Ready.
/// The OS can therefore choose among CPU, GPU, and Neural Engine on each Mac;
/// specialization never belongs to stop→text. Explicit modes remain benchmark
/// lanes for future device-matrix calibration.
public enum EncoderPlacement: String, Sendable, CaseIterable {
    case automatic
    case neuralEngine
    case gpu
}

/// How the optional acoustic-vocabulary pass is scheduled against the main
/// recognizer.
///
/// The reference mode preserves FluidAudio's whole-file parallel pass. The
/// shipping mode waits for the primary transcript, then produces evidence only
/// for spans that can pass the final rescorer's lexical gate. This is true for
/// short and long audio: speculative CTC competes with the primary encoder even
/// when there is no vocabulary candidate to correct.
public enum VocabularyInferenceScheduling: String, Sendable, CaseIterable {
    case alwaysParallel
    case candidateRegions
}

/// The only place in the entire project where FluidAudio is imported.
///
/// Everything else - including the dictation controller and its tests - works through
/// `ASREngineAdapting` from DictationCore. If the library API goes (and it
/// the documentation diverges from the tag in some places), only this file will have to be repaired.
public actor FluidAudioAdapter: ASREngineAdapting {
    private var models: AsrModels?
    private var manager: AsrManager?

    /// Collected term hint: everything a single recognition needs.
    ///
    /// Five fields instead of one would mean that they can be replaced by
    ///separately. Here they are replaced only entirely, and recognition takes
    /// snapshot once - otherwise editing the dictionary in the middle of the dictation would have time
    /// slip in evidence from one set of terms and a replacement rule from another.
    private struct VocabularyHelper: Sendable {
        let spotter: CtcKeywordSpotter
        let context: CustomVocabularyContext
        let rescorer: VocabularyRescorer
        let sizeConfig: ContextBiasingConstants.VocabSizeConfig
        let biasWeight: Float
        let lexicalGate: VocabularyLexicalGate
    }

    /// Only the part of FluidAudio's spotting result that rescoring consumes.
    /// Keyword detections belong to the disabled acoustic-rescue path and are
    /// intentionally not carried through the optimized scheduler.
    private struct VocabularyEvidence: Sendable {
        let logProbs: [[Float]]
        let frameDuration: Double
    }

    /// Immutable, allocation-bounded snapshot of the lexical half of the
    /// pinned FluidAudio rescorer's candidate decision.
    ///
    /// Canonical terms and aliases are normalized and converted to Characters
    /// once when the vocabulary changes. Recognition can then take this value
    /// together with the real rescorer/context snapshot and safely use it from
    /// child tasks without reading mutable actor state.
    struct VocabularyLexicalGate: Sendable {
        private struct Form: Sendable {
            let normalized: [Character]
            let canonical: [Character]
        }

        private let forms: [Form]
        private let minimumSimilarity: Float

        init(terms: [VocabularyBoost.Term], minimumSimilarity: Float) {
            self.minimumSimilarity = minimumSimilarity
            var seen = Set<String>()
            var cached: [Form] = []
            cached.reserveCapacity(terms.reduce(0) { $0 + 1 + $1.aliases.count })

            for term in terms {
                let canonical = FluidAudioAdapter.normalizeVocabularyCandidate(term.text)
                let canonicalCharacters = Array(canonical)
                for raw in [term.text] + term.aliases {
                    let normalized = FluidAudioAdapter.normalizeVocabularyCandidate(raw)
                    let key = canonical + "\u{0}" + normalized
                    guard !normalized.isEmpty, seen.insert(key).inserted else { continue }
                    cached.append(
                        Form(
                            normalized: Array(normalized),
                            canonical: canonicalCharacters
                        )
                    )
                }
            }
            forms = cached
        }

        /// Test/benchmark seam confirming that aliases are cached at load time,
        /// not rebuilt for each dictated phrase.
        var cachedFormCount: Int { forms.count }

        /// Return word-index spans for which the real CTC rescorer may change
        /// text. The result deliberately stays conservative: it may include a
        /// span rejected by stricter stop-word or acoustic checks, but it must
        /// never exclude one accepted by the final rescorer.
        func candidateWordSpans(words: [String]) -> [Range<Int>] {
            guard !words.isEmpty, !forms.isEmpty else { return [] }

            // Normalize every transcript word exactly once. Phrases are built
            // incrementally for the pinned rescorer's maximum four-word span.
            let normalizedWords = words.map {
                Array(FluidAudioAdapter.normalizeVocabularyCandidate($0))
            }
            var result: [Range<Int>] = []
            var candidateCache: [[Character]: Bool] = [:]

            for startIndex in normalizedWords.indices {
                let maximumLength = min(4, normalizedWords.count - startIndex)
                var phrase: [Character] = []
                var compound: [Character] = []

                for length in 1...maximumLength {
                    let word = normalizedWords[startIndex + length - 1]
                    if !word.isEmpty {
                        if !phrase.isEmpty { phrase.append(" ") }
                        phrase.append(contentsOf: word)
                        compound.append(contentsOf: word)
                    }
                    guard !phrase.isEmpty else { continue }

                    let canAffectText: Bool
                    if let cached = candidateCache[phrase] {
                        canAffectText = cached
                    } else {
                        canAffectText = forms.contains { form in
                            // The real rescorer deliberately leaves an exact
                            // canonical spelling untouched. Aliases remain
                            // valid candidates for that canonical term.
                            guard phrase != form.canonical else { return false }
                            if FluidAudioAdapter.vocabularyCandidateCanReachThreshold(
                                phrase,
                                form.normalized,
                                minimumSimilarity: minimumSimilarity
                            ) {
                                return true
                            }
                            guard compound != phrase else { return false }
                            return FluidAudioAdapter.vocabularyCandidateCanReachThreshold(
                                compound,
                                form.normalized,
                                minimumSimilarity: minimumSimilarity
                            )
                        }
                        candidateCache[phrase] = canAffectText
                    }

                    if canAffectText {
                        result.append(startIndex..<(startIndex + length))
                    }
                }
            }
            return result
        }
    }

    // Acoustic term hint: The CTC model looks for terms in the sound,
    // rescorer edits the TDT text based on her evidence. Everything is optional: no explicit
    // loading recognition works exactly as before.
    private var vocabulary: VocabularyHelper?

    /// Weights of the CTC model and its tokenizer. Kept separate from the term set,
    /// because they experience its editing: the list changes often, the weights never.
    private var ctcModels: CtcModels?
    private var ctcTokenizer: CtcTokenizer?
    private var ctcDirectory: URL?

    // Live preview: pseudo-streaming manager on the same scales as
    // batch path. His text is for eyes only during speech; source
    // the truth remains batch recognition of the finished record.
    private var previewManager: SlidingWindowAsrManager?
    private var previewTask: Task<Void, Never>?

    /// Is a preview launching right now, and which one?
    ///
    /// The generation resolves the dispute between start and stop, caught inside it:
    /// a launch whose generation has become outdated does not install its own manager.
    private var previewStarting = false
    private var previewGeneration = 0

    /// TDT decoder status.
    ///
    /// The library requires it as `inout` and reuses it between calls to
    /// streaming mode. Our regime is different: each dictation is independent,
    /// therefore the state is created anew before each recognition - otherwise
    /// the tail of the previous phrase would flow into the next one. Creation can throw
    /// error, so it is stored optionally.
    private var decoderState: TdtDecoderState?

    /// Whether to glue 80 ms of the previous window to the next one.
    ///
    /// The library has this flag enabled by default: in English it heals
    /// empty predictions at the junction of windows. On multilingual v3 it does the opposite,
    /// and this is written about in the library itself (issue #594): distribution shift
    /// of the first frame the decoder takes to the English prior, and the text at the junction
    /// **disappears silently**.
    ///
    /// It's turned off here because it's measured: on eight records with
    /// by switching the language within a phrase, the enabled flag consumed 47 words out of 1038,
    /// off - 17. The break is literally visible in the text: “The recovery pass
    /// reads.” - and the end of the sentence disappears without error. The parameter is left,
    /// so that the measurement can be repeated (`WAI_ASR_MEL_CONTEXT` in asr-bench).
    private let melChunkContext: Bool

    /// Encoder file option. Measurement of both is in `docs/benchmarks.md`.
    private let encoder: EncoderVariant

    /// Where the encoder is considered.
    private let encoderPlacement: EncoderPlacement

    /// Second pass of the decoder with arbitration at the junction of windows.
    ///
    /// The library keeps it disabled by default and only enables it for
    /// paths “v3 without mel context” - that is, exactly for ours. Worth the time
    /// therefore included according to the measurement result, and not according to the description.
    private let dualDecodeArbitration: Bool

    /// The ceiling of tokens per window for the TDT decoder.
    ///
    /// The library sets 150 and if it is exceeded **silently interrupts window parsing** -
    /// `break` from the loop, without an error and without a trace in the text. The symptom is the same as
    /// already cured mel-context: the middle of the phrase is missing.
    ///
    /// 150 is not always enough. The counter counts all decoded window tokens,
    /// including the two-second overlap, which is not included in the text - that is
    /// the budget for a new speech is less than the number in the setting. In dense Russian speech
    /// (340 words per minute, recording longer than one window) the ceiling was triggered and
    /// ate pieces: “each handler was **Until he finished**.” WER like this
    /// records 9.8% versus 4.3% without a break.
    ///
    /// 600 was selected by measurement: 200 is already enough for the densest speech, which
    /// managed to synthesize, then the text does not change at all; 600 gives triple
    /// the reserve and at the same time remains three times lower than the theoretical maximum of the window
    /// (187 frames × 10 tokens per frame = 1870), i.e. loop protection
    /// decoder is saved. The text on the body has not changed in a single character,
    /// speed too. The numbers are in `docs/benchmarks.md`.
    private let maxTokensPerChunk: Int

    /// Number of independent long-form windows submitted at once. Kept at
    /// the adapter boundary so the shipping value can be benchmarked against
    /// the same immutable FluidAudio revision instead of patched downstream.
    private let parallelChunkConcurrency: Int

    /// Scheduling policy for the auxiliary CTC vocabulary model. Kept at the
    /// adapter boundary so the optimized path can be compared byte-for-byte
    /// with FluidAudio's reference path in `asr-bench`.
    private let vocabularyScheduling: VocabularyInferenceScheduling

    public static let defaultMaxTokensPerChunk = 600
    /// FluidAudio's cross-device default. Six won one M4 long-form sweep, but
    /// four is the measured upstream device-matrix choice and avoids making an
    /// M4-only throughput result the memory/concurrency policy for every Mac.
    public static let defaultParallelChunkConcurrency = 4
    static let vocabularyChunkOverlapSamples = 32_000

    public init(
        melChunkContext: Bool = false,
        encoder: EncoderVariant = .palettized6bit,
        encoderPlacement: EncoderPlacement = .automatic,
        dualDecodeArbitration: Bool = false,
        maxTokensPerChunk: Int = FluidAudioAdapter.defaultMaxTokensPerChunk,
        parallelChunkConcurrency: Int = FluidAudioAdapter.defaultParallelChunkConcurrency,
        vocabularyScheduling: VocabularyInferenceScheduling = .candidateRegions
    ) {
        self.melChunkContext = melChunkContext
        self.encoder = encoder
        self.encoderPlacement = encoderPlacement
        self.dualDecodeArbitration = dualDecodeArbitration
        self.maxTokensPerChunk = maxTokensPerChunk
        self.parallelChunkConcurrency = max(1, parallelChunkConcurrency)
        self.vocabularyScheduling = vocabularyScheduling
    }

    /// For a test that guards the selected ceiling.
    var chunkTokenCeiling: Int { maxTokensPerChunk }

    /// For benchmark/configuration tests that guard the selected pool size.
    var longFormConcurrency: Int { parallelChunkConcurrency }

    /// Test and benchmark seam for the shipping CTC scheduler.
    var vocabularyInferenceScheduling: VocabularyInferenceScheduling { vocabularyScheduling }

    /// Pure scheduling policy used by both the product path and its benchmark
    /// comparison lane. `candidateRegions` always needs the TDT transcript
    /// first; only the explicit reference mode may overlap CTC with TDT.
    static func shouldStartVocabularyEvidenceInParallel(
        hasVocabulary: Bool,
        scheduling: VocabularyInferenceScheduling
    ) -> Bool {
        hasVocabulary && scheduling == .alwaysParallel
    }

    /// For the test that guards the portable automatic default.
    var placement: EncoderPlacement { encoderPlacement }

    static func encoderComputeUnits(for placement: EncoderPlacement) -> MLComputeUnits {
        switch placement {
        case .automatic: .all
        case .neuralEngine: .cpuAndNeuralEngine
        case .gpu: .cpuAndGPU
        }
    }

    /// For a test that guards the selected flag value.
    var usesMelChunkContext: Bool { melChunkContext }

    /// Load the model from the prepared directory.
    ///
    /// There is no network here: `AsrModels.load(from:)` reads already deployed bundles.
    /// This is confirmed by the library documentation (Documentation/ASR/ManualModelLoading.md)
    /// and is checked by a separate run in a sandbox with a prohibited network.
    public func loadModels(from directory: URL) async throws {
        // OpenRamble controls the model independently: the user explicitly
        // downloads the committed manifest, after which each file is checked
        // according to SHA-256. FluidAudio should not attempt to "fix" damage to its
        // network boot. The flag is placed here - at the only import border
        // FluidAudio - before any loader in all LocalASR clients, including bench.
        ModelHub.offlineMode = true
        guard models == nil else { return }

        // `.int8` is the name of the file variant in library terms
        // (Encoder.mlmodelc vs EncoderInt4.mlmodelc), not a description of the quantization.
        // In fact, this encoder is quantized with a 6-bit palette - as indicated in
        // CC BY license attribution.
        let precision: ParakeetEncoderPrecision = encoder == .int4 ? .int4 : .int8

        guard AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: precision) else {
            throw ASREngineError.modelsUnavailable(
                "\(directory.lastPathComponent) doesn't contain the full set of Parakeet v3 bundles"
            )
        }

        do {
            let loaded = try await AsrModels.load(
                from: directory,
                version: .v3,
                encoderPrecision: precision,
                encoderComputeUnits: Self.encoderComputeUnits(for: encoderPlacement)
            )
            let manager = AsrManager(
                config: ASRConfig(
                    tdtConfig: TdtConfig(maxTokensPerChunk: maxTokensPerChunk),
                    parallelChunkConcurrency: parallelChunkConcurrency,
                    melChunkContext: melChunkContext,
                    dualDecodeArbitration: dualDecodeArbitration
                )
            )
            try await manager.loadModels(loaded)

            self.models = loaded
            self.manager = manager
        } catch {
            throw ASREngineError.modelsUnavailable(error.localizedDescription)
        }
    }

    /// Test seam: confirms that the setting belongs to the adapter and not just one
    /// from calling applications. Don't use it instead of `loadModels` at runtime.
    static func enforceOfflineMode() {
        ModelHub.offlineMode = true
    }

    /// Load or rebuild the acoustic term hint.
    ///
    /// Called both during warm-up and every time a person corrects the dictionary:
    /// the set of terms is reassembled on a live adapter, the weights of the CTC model when
    /// this remains loaded. Previously there was `guard spotter == nil`,
    /// and because of it, editing the dictionary reached text replacements immediately, and
    /// acoustics - only after restarting the application. The dictionary behaved
    /// differently in its two halves, and there was nothing to explain this to the person.
    ///
    /// Empty list - conscious “turned off”: the prompt is removed, weights
    /// are released, recognition proceeds as without it. This is also a dictionary edit:
    /// a person has erased all terms and has the right to see the result immediately.
    ///
    /// There is no network here according to the same scheme as the main model:
    /// `CtcModels.loadDirect(from:)` reads already deployed bundles
    /// (MelSpectrogram.mlmodelc, AudioEncoder.mlmodelc, vocab.json) and crashes,
    /// if they are missing.
    public func loadVocabularyModels(from directory: URL, boost: VocabularyBoost) async throws {
        ModelHub.offlineMode = true
        try Task.checkCancellation()

        guard !boost.isEmpty else {
            try Task.checkCancellation()
            vocabulary = nil
            ctcModels = nil
            ctcTokenizer = nil
            ctcDirectory = nil
            return
        }

        // Weights and tokenizer survive list edits. We only ship them when
        // they are not there yet or when the folder has changed.
        let models: CtcModels
        let tokenizer: CtcTokenizer
        if let ctcModels, let ctcTokenizer, ctcDirectory == directory {
            models = ctcModels
            tokenizer = ctcTokenizer
        } else {
            do {
                models = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
                tokenizer = try await CtcTokenizer.load(from: directory)
            } catch {
                throw ASREngineError.modelsUnavailable(error.localizedDescription)
            }
            try Task.checkCancellation()
            ctcModels = models
            ctcTokenizer = tokenizer
            ctcDirectory = directory
        }

        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)

        // Term without CTC tokens rescorer silently skips - tokenization
        // is required here, this is the inclusion of the term in the tooltips.
        var terms: [CustomVocabularyTerm] = []
        for (index, term) in boost.terms.enumerated() {
            let tokenIds = tokenizer.encode(term.text)
            guard !tokenIds.isEmpty else {
                // The text of the term is not intentionally included in the error: content
                // dictionary - human data, like the dictation text.
                throw VocabularyBoostError.termNotTokenizable(index: index + 1)
            }
            terms.append(
                CustomVocabularyTerm(
                    text: term.text,
                    aliases: term.aliases.isEmpty ? nil : term.aliases,
                    ctcTokenIds: tokenIds
                )
            )
        }

        let context = CustomVocabularyContext(terms: terms, minSimilarity: boost.minSimilarity)
        // The acoustic rescue pass is disabled intentionally: it replaces words
        // according to one acoustic evidence, bypassing the threshold of similarity, and on our
        // in the body it was he who turned “in the center” into Sentry and “comet” into
        // commit. The library itself recommends turning it off for short
        // dictionaries (#702, #724); ours is dozens of terms, not hundreds.
        let rescorer: VocabularyRescorer
        do {
            rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: context,
                config: VocabularyRescorer.Config(
                    spotterRescueMinSimilarity: 0.5,
                    spotterRescueMultiWordMinSimilarity: 0.5,
                    spotterRescueEnabled: false
                ),
                ctcModelDirectory: directory
            )
        } catch {
            throw ASREngineError.modelsUnavailable(error.localizedDescription)
        }

        let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count)
        let helper = VocabularyHelper(
            spotter: spotter,
            context: context,
            rescorer: rescorer,
            sizeConfig: sizeConfig,
            biasWeight: boost.biasWeight,
            lexicalGate: VocabularyLexicalGate(
                terms: boost.terms,
                minimumSimilarity: max(sizeConfig.minSimilarity, context.minSimilarity)
            )
        )
        // Substitute atomically and last: an already-running recognition keeps
        // its previous immutable snapshot; the next one receives this helper.
        try Task.checkCancellation()
        vocabulary = helper
    }

    /// How many terms are currently in the acoustic set. Need a test that
    /// Ensures that the set is reassembled without restarting.
    var boostedTermCount: Int { vocabulary?.context.terms.count ?? 0 }

    /// Materialize the optional CTC prediction graph before the recognizer is
    /// advertised as Ready.
    ///
    /// The shipping scheduler starts CTC only after TDT finds a lexical
    /// candidate. Silence therefore cannot reach this path through normal
    /// transcription warm-up. Calling the evidence-only API directly keeps
    /// the first real custom-term dictation off the cold path while preserving
    /// candidate-first scheduling for every product request.
    func warmUpVocabularyInference() async throws {
        guard let helper = vocabulary else { return }
        _ = try await Self.vocabularyEvidenceOnly(
            samples: [Float](repeating: 0, count: 16_000),
            helper: helper
        )
    }

    /// Start live preview. Requires loaded main model: weights
    /// are divided between batch recognition and preview, there is no second copy.
    ///
    /// **There is nothing to transfer the language to the preview.** Stream library manager
    /// 0.15.5 does not accept the language hint at all - neither in the configuration nor in
    /// `startStreaming`. Therefore, the preview always runs on autodetection,
    /// even when a person has chosen the language explicitly, and the text in front of his eyes can
    /// diverge from the final one. This can only be done from the library side;
    /// batch recognition remains the source of truth, and it respects language.
    public func startPreview(
        onUpdate: @escaping @Sendable (_ confirmed: String, _ volatile: String) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let models else { throw ASREngineError.modelsNotLoaded }
        guard previewManager == nil, !previewStarting else { return }

        // The launch request is placed **before** the first await.
        //
        // The actor does not hold the queue: on each await the next one is started inside
        // call. While the launch was waiting for the loading of the scales and the start of the stream, `stopPreview`
        // managed to log in, see an empty `previewManager` and do nothing -
        // and then the launch brought the matter to completion. Preview remained
        // running forever, the next dictation didn't receive it at all, and
        // the person saw the text of the previous session in front of him.
        previewStarting = true
        previewGeneration &+= 1
        let generation = previewGeneration

        // The default 11-second center window is tuned for stable long-form
        // transcription, not visual feedback. A compact preview window produces the
        // first words after roughly one second and then refreshes continuously. The
        // final file transcription remains the source of truth for inserted text.
        let preview = SlidingWindowAsrManager(
            config: SlidingWindowAsrConfig(
                chunkSeconds: 1.0,
                hypothesisChunkSeconds: 0.5,
                leftContextSeconds: 0.5,
                rightContextSeconds: 0.25,
                minContextForConfirmation: 3.0,
                confirmationThreshold: 0.8
            )
        )
        do {
            try await preview.loadModels(models)
            try Task.checkCancellation()
            try await preview.startStreaming(source: .microphone)
            try Task.checkCancellation()
        } catch {
            await preview.cancel()
            if previewGeneration == generation { previewStarting = false }
            throw error
        }

        // While they were loading, they could ask you to stop - or start again.
        // Then this manager is no longer needed by anyone and must be collapsed here,
        // otherwise he will remain working in the shadows.
        guard previewGeneration == generation else {
            await preview.cancel()
            return
        }
        previewStarting = false
        previewManager = preview

        previewTask = Task { [weak preview] in
            guard let preview else { return }
            var lastEmit = ContinuousClock.now - .seconds(1)
            for await _ in await preview.transcriptionUpdates {
                if Task.isCancelled { break }
                // Keep presentation smooth while allowing each low-latency window through.
                let now = ContinuousClock.now
                guard lastEmit.duration(to: now) >= .milliseconds(100) else { continue }
                lastEmit = now
                // The semantics of the update text field changes between modes
                // libraries; own confirmed/volatile - stable
                // source. We read them after each event.
                let confirmed = await preview.confirmedTranscript
                let volatile = await preview.volatileTranscript
                onUpdate(confirmed, volatile)
            }
        }
    }

    /// Feed live samples to the preview (16 kHz, mono, Float32).
    public func feedPreview(samples: [Float]) async {
        guard let previewManager, !samples.isEmpty else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }
        await previewManager.streamAudio(buffer)
    }

    /// Stop the preview and release its state. General model weights
    /// and remain loaded for batch recognition.
    ///
    /// Stops the launch that is happening right now: generation change
    /// causes it to collapse its manager instead of putting it
    /// to the place of the already stopped one.
    public func stopPreview() async {
        previewGeneration &+= 1
        previewStarting = false
        previewTask?.cancel()
        previewTask = nil
        if let previewManager {
            await previewManager.cancel()
        }
        previewManager = nil
    }

    /// Is there a preview going on right now? Test seam to check that
    /// stopping in the middle of a startup really does stop it.
    var isPreviewRunning: Bool { previewManager != nil }

    /// Whether a start request has entered the actor but has not installed its manager yet.
    /// Used to make the start/stop race test deterministic.
    var isPreviewStarting: Bool { previewStarting }

    public func transcribe(samples: [Float]) async throws -> DictationCore.ASRResult {
        try await transcribe(samples: samples, languageHint: nil)
    }

    /// Languages that the engine accepts as hints (BCP-47 codes).
    ///
    /// The list is a property of the engine, not the product, so it lives on the only
    /// FluidAudio import border. The UI builds from it the language selection.
    public static var supportedLanguageHints: [String] {
        Language.allCases.map(\.rawValue)
    }

    public func transcribe(
        samples: [Float],
        languageHint: String?
    ) async throws -> DictationCore.ASRResult {
        // The hint is checked before everything else: unknown code - error
        // of the caller, and it must be visible and not silently become "auto".
        let language: Language?
        if let languageHint {
            guard let parsed = Language(rawValue: languageHint) else {
                throw ASREngineError.inferenceFailed(
                    "unsupported language hint: \(languageHint)"
                )
            }
            language = parsed
        } else {
            language = nil
        }

        guard let manager else {
            throw ASREngineError.modelsNotLoaded
        }
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("empty buffer")
        }

        let started = ContinuousClock.now
        // We calculate the duration ourselves: the library in this version returns zero,
        // and the indicator “how many times faster than real time” depends on it.
        let audioDuration = Double(samples.count) / AudioFileReader.targetSampleRate
        let text: String
        let timings: [TokenTiming]?
        do {
            // The set of terms is taken once for the entire dictation: editing the dictionary
            // in the middle of recognition has no right to replace it between
            // acoustic passage and text editing.
            let helper = vocabulary

            // Construct fallible decoder state before spawning unstructured
            // evidence work. If this fails, there is no child task to orphan.
            var state = try TdtDecoderState()

            // The product scheduler always waits for TDT, including on a single
            // 15-second window. Starting CTC speculatively made ordinary short
            // dictations contend for the accelerator even when their transcript
            // contained no term the final rescorer could change. The explicit
            // reference mode remains available to reproduce the old overlap.
            let shouldRunCTCInParallel = Self.shouldStartVocabularyEvidenceInParallel(
                hasVocabulary: helper != nil,
                scheduling: vocabularyScheduling
            )
            let evidenceTask = shouldRunCTCInParallel
                ? helper.map { helper in
                    Task { try await Self.spotKeywords(samples: samples, helper: helper) }
                }
                : nil

            // Each dictation is independent - the state above starts clean.
            // nil - auto-detection by sound. The model covers 25 European
            // languages; a hard choice breaks mixed speech, so the hint is
            // only explicit human choice when emphasis is shifted away from autodetection.
            let result = try await {
                do {
                    return try await manager.transcribe(
                        samples,
                        decoderState: &state,
                        language: language
                    )
                } catch {
                    evidenceTask?.cancel()
                    _ = try? await evidenceTask?.value
                    throw error
                }
            }()
            decoderState = state

            // The final rescorer can only change spans that pass its string
            // similarity gate. This conservative prefilter mirrors the pinned
            // FluidAudio normalization/formula and is already used to schedule
            // long-form CTC windows. Apply the same proof to short dictations:
            // finish the parallel CTC task (so no background inference leaks
            // into the next take), but skip the O(words × terms × frames)
            // rescore when no replacement can possibly survive its guards.
            let candidateRegions = helper.map {
                Self.vocabularyCandidateRegions(
                    text: result.text,
                    timings: result.tokenTimings,
                    audioSampleCount: samples.count,
                    helper: $0
                )
            } ?? []

            let spotted: VocabularyEvidence?
            if let evidenceTask {
                let evidence = try await withTaskCancellationHandler {
                    try await evidenceTask.value
                } onCancel: {
                    evidenceTask.cancel()
                }
                spotted = candidateRegions.isEmpty ? nil : evidence
            } else if let helper, vocabularyScheduling == .candidateRegions {
                spotted = try await Self.spotKeywords(
                    samples: samples,
                    candidateRegions: candidateRegions,
                    helper: helper
                )
            } else {
                spotted = nil
            }
            // The prompter edits the text based on the acoustic evidence of the CTC model.
            // Timings remain from the original tokens: replacing a word does not move
            // its place in the recording, and consumers of word-by-word timings, which
            // the letter-by-letter accuracy of the replaced word is important, it is not in the product.
            text = Self.rescore(
                text: result.text,
                timings: result.tokenTimings,
                spotted: spotted,
                helper: helper
            ) ?? result.text
            timings = result.tokenTimings
        } catch is CancellationError {
            throw ASREngineError.cancelled
        } catch {
            throw ASREngineError.inferenceFailed(error.localizedDescription)
        }
        let elapsed = started.duration(to: .now)

        return DictationCore.ASRResult(
            text: text,
            words: Self.words(from: timings),
            audioDuration: audioDuration,
            processingDuration: elapsed.seconds
        )
    }

    /// Search for terms in audio.
    ///
    /// Not an actor method intentionally: it works based on the passed snapshot of the set and not to
    /// which mutable state is not addressed - that’s the only reason it can be
    /// conduct simultaneously with analysis, without fear of editing the dictionary in the middle.
    /// CTC-inference error with a configured prompter - a real error
    /// recognition: a person has included terms and has the right to know that they are not
    /// worked, and the record will be saved for Retry.
    private static func spotKeywords(
        samples: [Float],
        helper: VocabularyHelper?
    ) async throws -> VocabularyEvidence? {
        guard let helper else { return nil }
        // The adapter consumes acoustic log-probabilities, not FluidAudio's
        // keyword detections. Running the per-term dynamic program here made
        // short-dictation latency grow linearly with the user's dictionary,
        // then discarded every detection. The final rescorer below still uses
        // the real immutable vocabulary snapshot, so this removes only dead
        // work and keeps the evidence and output semantics unchanged.
        return try await vocabularyEvidenceOnly(samples: samples, helper: helper)
    }

    /// Produce a sparse full-timeline CTC matrix from the exact 15-second
    /// windows used by FluidAudio 0.15.5. Every frame a candidate can inspect
    /// is identical to the reference whole-file pass; uninspected gaps are
    /// blank-dominant and therefore cannot create a replacement.
    private static func spotKeywords(
        samples: [Float],
        candidateRegions: [Range<Int>],
        helper: VocabularyHelper
    ) async throws -> VocabularyEvidence? {
        let chunkSize = ASRConstants.maxModelSamples
        let overlap = vocabularyChunkOverlapSamples
        guard !candidateRegions.isEmpty else { return nil }
        guard samples.count > chunkSize else {
            // Preserve reference behavior if scheduling constants ever drift.
            return try await spotKeywords(samples: samples, helper: helper)
        }

        let chunks = vocabularyChunkRanges(audioSampleCount: samples.count)
        let selected = vocabularySelectedChunkIndices(
            audioSampleCount: samples.count,
            candidateRegions: candidateRegions
        )
        guard !selected.isEmpty else { return nil }

        var results: [(index: Int, evidence: VocabularyEvidence)] = []
        for index in selected {
            try Task.checkCancellation()
            let chunk = chunks[index]
            let evidence = try await vocabularyEvidenceOnly(
                samples: Array(samples[chunk]),
                helper: helper
            )
            try Task.checkCancellation()
            guard !evidence.logProbs.isEmpty else { continue }
            results.append((index: index, evidence: evidence))
        }

        guard
            let full = results.first(where: {
                let chunk = chunks[$0.index]
                return chunk.count == chunkSize
            }),
            let rowWidth = results.first?.evidence.logProbs.first?.count,
            rowWidth > helper.spotter.blankId,
            full.evidence.frameDuration > 0
        else { return nil }

        let frameDuration = full.evidence.frameDuration
        let overlapFrames = Int(
            Double(overlap) / AudioFileReader.targetSampleRate / frameDuration
        )
        let frameStride = full.evidence.logProbs.count - overlapFrames
        guard frameStride > 0 else { return nil }

        let frameCount = results.map {
            $0.index * frameStride + $0.evidence.logProbs.count
        }.max() ?? 0
        var blank = [Float](repeating: -Float.infinity, count: rowWidth)
        blank[helper.spotter.blankId] = 0
        var combined = [[Float]](repeating: blank, count: frameCount)
        var filled = [Bool](repeating: false, count: frameCount)

        for result in results {
            let offset = result.index * frameStride
            for (localIndex, row) in result.evidence.logProbs.enumerated() {
                let globalIndex = offset + localIndex
                guard globalIndex < combined.count else { break }
                if filled[globalIndex] {
                    combined[globalIndex] = mergeVocabularyOverlap(
                        existing: combined[globalIndex],
                        incoming: row
                    )
                } else {
                    combined[globalIndex] = row
                    filled[globalIndex] = true
                }
            }
        }

        return VocabularyEvidence(logProbs: combined, frameDuration: frameDuration)
    }

    /// Canonical FluidAudio 0.15.5 windows in source-sample coordinates.
    static func vocabularyChunkRanges(audioSampleCount: Int) -> [Range<Int>] {
        guard audioSampleCount > 0 else { return [] }
        let chunkSize = ASRConstants.maxModelSamples
        let stride = chunkSize - vocabularyChunkOverlapSamples
        var chunks: [Range<Int>] = []
        var start = 0
        while start < audioSampleCount {
            let end = min(start + chunkSize, audioSampleCount)
            chunks.append(start..<end)
            if end >= audioSampleCount { break }
            start += stride
        }
        return chunks
    }

    /// A 600 ms candidate margin is wider than FluidAudio's 500 ms CTC
    /// search margin plus one encoder frame. Therefore every chunk that can
    /// contribute a frame to the final score overlaps the candidate range
    /// directly; unconditional neighboring chunks would only duplicate work.
    static func vocabularySelectedChunkIndices(
        audioSampleCount: Int,
        candidateRegions: [Range<Int>]
    ) -> [Int] {
        let chunks = vocabularyChunkRanges(audioSampleCount: audioSampleCount)
        let directlySelected = chunks.enumerated().compactMap {
            index, chunk in
            candidateRegions.contains(where: { $0.overlaps(chunk) }) ? index : nil
        }
        var selected = Set(directlySelected)
        for index in directlySelected where chunks[index].count < ASRConstants.maxModelSamples {
            // The reference timeline uses frame duration from its first full
            // chunk. A candidate isolated inside the trailing partial chunk
            // therefore also needs its full predecessor to reconstruct the
            // same grid and overlap.
            if index > 0 { selected.insert(index - 1) }
        }
        return selected.sorted()
    }

    /// Ask the public spotter API only for its acoustic evidence. Its detection
    /// list is consumed exclusively by FluidAudio's acoustic-rescue mode, which
    /// this adapter disables. Passing the real term list here would repeat a
    /// term-by-frame dynamic program after every cancellable chunk and then
    /// discard every detection.
    private static func vocabularyEvidenceOnly(
        samples: [Float],
        helper: VocabularyHelper
    ) async throws -> VocabularyEvidence {
        let result = try await helper.spotter.spotKeywordsWithLogProbs(
            audioSamples: samples,
            customVocabulary: CustomVocabularyContext(terms: []),
            minScore: nil
        )
        return VocabularyEvidence(logProbs: result.logProbs, frameDuration: result.frameDuration)
    }

    /// Locate every word span that can reach constrained CTC scoring.
    ///
    /// A deliberately permissive string prefilter locates possible replacement
    /// spans without running FluidAudio's constrained CTC dynamic program on a
    /// synthetic whole-record timeline. It uses the pinned dependency's exact
    /// normalization and Levenshtein formula with the lowest configured
    /// candidate threshold (before stricter span/stop-word/length guards). It
    /// can therefore schedule an unnecessary window, but cannot discard a
    /// candidate the final rescorer would accept.
    private static func vocabularyCandidateRegions(
        text: String,
        timings: [TokenTiming]?,
        audioSampleCount: Int,
        helper: VocabularyHelper
    ) -> [Range<Int>] {
        guard let timings, !text.isEmpty else { return [] }
        let words = buildWordTimings(from: timings)
        // The pinned rescorer has the same word-timing guard, so acoustic
        // evidence provably cannot change text in this case.
        guard !words.isEmpty else { return [] }

        let sampleRate = AudioFileReader.targetSampleRate
        // The rescorer converts seconds to frames with independent integer
        // truncation. Its 500 ms search margin plus more than one native
        // ~80 ms frame on either side keeps every inspected frame inside a
        // selected canonical chunk.
        let margin = 0.6
        var regions: [Range<Int>] = []
        let candidateSpans = helper.lexicalGate.candidateWordSpans(words: words.map(\.word))

        for span in candidateSpans {
            let lower = max(
                0,
                Int(floor((words[span.lowerBound].startTime - margin) * sampleRate))
            )
            let upper = min(
                audioSampleCount,
                Int(ceil((words[span.upperBound - 1].endTime + margin) * sampleRate))
            )
            if lower < upper { regions.append(lower..<upper) }
        }

        guard !regions.isEmpty else { return [] }
        return mergeVocabularyCandidateRegions(regions)
    }

    /// Kept byte-for-byte with FluidAudio 0.15.5's private candidate
    /// normalization. The dependency is revision-pinned and parity tests guard
    /// this optimization before an update can ship.
    static func normalizeVocabularyCandidate(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-"))
        var result = ""
        var lastWasSpace = true
        for scalar in text.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                result.append(Character(scalar))
                lastWasSpace = false
            } else if scalar == " " || scalar == "\t" || scalar == "\n" {
                if !lastWasSpace && !result.isEmpty {
                    result.append(" ")
                    lastWasSpace = true
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func vocabularyCandidateSimilarity(_ left: String, _ right: String) -> Float {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        let maximumLength = max(leftCharacters.count, rightCharacters.count)
        guard maximumLength > 0 else { return 1 }
        // Independent full-width reference for the bounded hot-path decision
        // below and for dependency-parity tests.
        var previous = Array(0...rightCharacters.count)
        var current = [Int](repeating: 0, count: rightCharacters.count + 1)
        for leftIndex in leftCharacters.indices {
            current[0] = leftIndex + 1
            for rightIndex in rightCharacters.indices {
                let substitution = previous[rightIndex]
                    + (leftCharacters[leftIndex] == rightCharacters[rightIndex] ? 0 : 1)
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    substitution
                )
            }
            swap(&previous, &current)
        }
        let distance = previous[rightCharacters.count]
        return 1 - Float(distance) / Float(maximumLength)
    }

    /// Exact FluidAudio similarity decision without computing matrix cells that
    /// cannot possibly fit under the requested edit-distance threshold.
    /// Cached vocabulary Characters are passed directly by the hot lexical gate.
    static func vocabularyCandidateCanReachThreshold(
        _ left: [Character],
        _ right: [Character],
        minimumSimilarity: Float
    ) -> Bool {
        guard !minimumSimilarity.isNaN else { return false }
        let maximumLength = max(left.count, right.count)
        guard maximumLength > 0 else { return 1 >= minimumSimilarity }
        guard let maximumDistance = maximumAcceptedVocabularyDistance(
            maximumLength: maximumLength,
            minimumSimilarity: minimumSimilarity
        ) else { return false }
        guard abs(left.count - right.count) <= maximumDistance else { return false }
        guard let distance = boundedVocabularyLevenshteinDistance(
            left,
            right,
            maximumDistance: maximumDistance
        ) else { return false }

        // Keep the final Float formula byte-for-byte equivalent to the pinned
        // rescorer. The distance bound is only an optimization, never a change
        // to a rounding-boundary decision.
        return 1 - Float(distance) / Float(maximumLength) >= minimumSimilarity
    }

    /// Greatest integer edit distance whose Float similarity can still pass.
    /// The small adjustment loops protect exact boundary behavior from Float
    /// rounding instead of relying on a Double/floor approximation.
    private static func maximumAcceptedVocabularyDistance(
        maximumLength: Int,
        minimumSimilarity: Float
    ) -> Int? {
        guard maximumLength > 0 else { return minimumSimilarity <= 1 ? 0 : nil }
        if minimumSimilarity <= 0 { return maximumLength }
        guard minimumSimilarity <= 1 else { return nil }

        let accepts: (Int) -> Bool = { distance in
            1 - Float(distance) / Float(maximumLength) >= minimumSimilarity
        }
        var estimate = Int((1 - minimumSimilarity) * Float(maximumLength))
        estimate = min(maximumLength, max(0, estimate))
        while estimate > 0, !accepts(estimate) { estimate -= 1 }
        while estimate < maximumLength, accepts(estimate + 1) { estimate += 1 }
        return accepts(estimate) ? estimate : nil
    }

    /// Threshold-banded Levenshtein. A returned distance is the exact full-DP
    /// result; `nil` only means the exact result is greater than the bound.
    private static func boundedVocabularyLevenshteinDistance(
        _ rawLeft: [Character],
        _ rawRight: [Character],
        maximumDistance: Int
    ) -> Int? {
        guard maximumDistance >= 0 else { return nil }
        // Put the shorter sequence on the DP column axis to cap scratch storage.
        let left: [Character]
        let right: [Character]
        if rawRight.count <= rawLeft.count {
            left = rawLeft
            right = rawRight
        } else {
            left = rawRight
            right = rawLeft
        }
        guard abs(left.count - right.count) <= maximumDistance else { return nil }
        if right.isEmpty { return left.count <= maximumDistance ? left.count : nil }

        let sentinel = maximumDistance + 1
        var previous = [Int](repeating: sentinel, count: right.count + 1)
        var current = [Int](repeating: sentinel, count: right.count + 1)
        for column in 0...min(right.count, maximumDistance) {
            previous[column] = column
        }

        for row in 1...left.count {
            let lower = max(1, row - maximumDistance)
            let upper = min(right.count, row + maximumDistance)
            current[0] = row <= maximumDistance ? row : sentinel
            if lower > 1 { current[lower - 1] = sentinel }

            var rowMinimum = sentinel
            if lower <= upper {
                for column in lower...upper {
                    let substitution = previous[column - 1]
                        + (left[row - 1] == right[column - 1] ? 0 : 1)
                    current[column] = min(
                        sentinel,
                        previous[column] + 1,
                        current[column - 1] + 1,
                        substitution
                    )
                    rowMinimum = min(rowMinimum, current[column])
                }
            }
            if upper < right.count { current[upper + 1] = sentinel }
            guard rowMinimum <= maximumDistance else { return nil }
            swap(&previous, &current)
        }

        let distance = previous[right.count]
        return distance <= maximumDistance ? distance : nil
    }

    /// Merge overlapping candidate windows so the chunk selector stays small
    /// even when several aliases point to the same spoken phrase.
    private static func mergeVocabularyCandidateRegions(
        _ regions: [Range<Int>]
    ) -> [Range<Int>] {
        let sorted = regions.sorted {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound < $1.upperBound
                : $0.lowerBound < $1.lowerBound
        }
        var merged: [Range<Int>] = []
        for region in sorted {
            guard let last = merged.last else {
                merged.append(region)
                continue
            }
            if region.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, region.upperBound)
            } else {
                merged.append(region)
            }
        }
        return merged
    }

    /// Actor-isolated test seam for candidate localization.
    func vocabularyCandidateRegions(
        text: String,
        timings: [TokenTiming],
        audioSampleCount: Int
    ) -> [Range<Int>] {
        guard let vocabulary else { return [] }
        return Self.vocabularyCandidateRegions(
            text: text,
            timings: timings,
            audioSampleCount: audioSampleCount,
            helper: vocabulary
        )
    }

    /// Log-mean-exp in probability space, matching FluidAudio 0.15.5's
    /// `CtcKeywordSpotter.mergeOverlapFrame` exactly.
    static func mergeVocabularyOverlap(existing: [Float], incoming: [Float]) -> [Float] {
        let count = min(existing.count, incoming.count)
        guard count > 0 else { return existing }
        let log2: Float = 0.69314718
        var merged = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let left = existing[index]
            let right = incoming[index]
            let maximum = max(left, right)
            if maximum == -Float.infinity {
                merged[index] = -Float.infinity
            } else {
                merged[index] = maximum
                    + logf(expf(left - maximum) + expf(right - maximum))
                    - log2
            }
        }
        return merged
    }

    /// Correct the text based on already obtained acoustic evidence.
    ///
    /// Returns `nil` when the hint is not configured or there is nothing to change.
    private static func rescore(
        text: String,
        timings: [TokenTiming]?,
        spotted: VocabularyEvidence?,
        helper: VocabularyHelper?
    ) -> String? {
        guard let helper, let spotted else { return nil }
        guard let timings, !timings.isEmpty, !text.isEmpty else { return nil }
        // Empty log-probs are not a crash, but “there is less than one frame of sound”:
        // there is nothing to suggest to such records.
        guard !spotted.logProbs.isEmpty else { return nil }

        let output = helper.rescorer.ctcTokenRescore(
            transcript: text,
            tokenTimings: timings,
            logProbs: spotted.logProbs,
            frameDuration: spotted.frameDuration,
            cbw: helper.biasWeight,
            marginSeconds: 0.5,
            minSimilarity: max(helper.sizeConfig.minSimilarity, helper.context.minSimilarity)
        )
        guard output.wasModified else { return nil }
        // Resorer replaces the word along with the sign stuck to it: on long
        // records of 450 characters reached 347 (docs/benchmarks.md). We return
        // lost without touching a single word.
        return PunctuationReattachment.restore(original: text, rescored: output.text)
    }

    public func unload() async {
        await stopPreview()
        await manager?.cleanup()
        manager = nil
        models = nil
        decoderState = nil
        vocabulary = nil
        ctcModels = nil
        ctcTokenizer = nil
        ctcDirectory = nil
    }

    /// Glue together word-by-word timings from tokens.
    ///
    /// Parakeet gives the result by tokens, not by words: subwords begin
    /// without a leading space, so the word boundary is a token that is so
    /// begins with a space.
    static func words(from timings: [TokenTiming]?) -> [DictationCore.ASRResult.Word] {
        guard let timings, !timings.isEmpty else { return [] }

        var words: [DictationCore.ASRResult.Word] = []
        var current: (text: String, start: TimeInterval, end: TimeInterval, confidence: Double)?

        for timing in timings {
            // The library gives tokens with a leading " " or with a regular space -
            // both mean the beginning of a new word.
            let raw = timing.token
            let startsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ")
            let cleaned = raw
                .replacingOccurrences(of: "▁", with: "")
                .trimmingCharacters(in: .whitespaces)

            if cleaned.isEmpty { continue }

            if startsWord, let pending = current {
                words.append(
                    .init(
                        text: pending.text,
                        start: pending.start,
                        end: pending.end,
                        confidence: pending.confidence
                    )
                )
                current = nil
            }

            if var pending = current {
                pending.text += cleaned
                pending.end = timing.endTime
                pending.confidence = min(pending.confidence, Double(timing.confidence))
                current = pending
            } else {
                current = (cleaned, timing.startTime, timing.endTime, Double(timing.confidence))
            }
        }

        if let pending = current {
            words.append(
                .init(
                    text: pending.text,
                    start: pending.start,
                    end: pending.end,
                    confidence: pending.confidence
                )
            )
        }
        return words
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
