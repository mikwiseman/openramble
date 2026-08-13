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
/// Where the 425 MB encoder runs. GPU is the default, and the reason is a
/// cliff, not a race: the Neural Engine path depends on a system-managed
/// program cache (`com.apple.e5rt.e5bundlecache`) that macOS purges under
/// pressure — and with it purged, every load pays ~16 s of ANE
/// specialization (measured on a 24 GB M-series with the cache found
/// empty in the field). The GPU path compiles through MPSGraph in ≤7 s
/// worst / 0.3 s typical, and per-window inference is comparable
/// (FluidAudio's own numbers: 17.8 ms GPU vs 23.5 ms ANE, WER-neutral;
/// our bench: identical transcript). A dictation product needs the
/// predictable engine, not the occasionally-fastest one.
public enum EncoderPlacement: String, Sendable, CaseIterable {
    case neuralEngine
    case gpu
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

    public init(
        melChunkContext: Bool = false,
        encoder: EncoderVariant = .palettized6bit,
        encoderPlacement: EncoderPlacement = .gpu,
        dualDecodeArbitration: Bool = false,
        maxTokensPerChunk: Int = 600
    ) {
        self.melChunkContext = melChunkContext
        self.encoder = encoder
        self.encoderPlacement = encoderPlacement
        self.dualDecodeArbitration = dualDecodeArbitration
        self.maxTokensPerChunk = maxTokensPerChunk
    }

    /// For a test that guards the selected ceiling.
    var chunkTokenCeiling: Int { maxTokensPerChunk }

    /// For the test that guards the GPU default.
    var placement: EncoderPlacement { encoderPlacement }

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
                encoderComputeUnits: encoderPlacement == .gpu ? .cpuAndGPU : nil
            )
            let manager = AsrManager(
                config: ASRConfig(
                    tdtConfig: TdtConfig(maxTokensPerChunk: maxTokensPerChunk),
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

        // Substitution entirely and with the last action: recognition started before
        // of this line, it will be completed on the previous set, the next one will be taken by the new one.
        try Task.checkCancellation()
        vocabulary = VocabularyHelper(
            spotter: spotter,
            context: context,
            rescorer: rescorer,
            sizeConfig: ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count),
            biasWeight: boost.biasWeight
        )
    }

    /// How many terms are currently in the acoustic set. Need a test that
    /// Ensures that the set is reassembled without restarting.
    var boostedTermCount: Int { vocabulary?.context.terms.count ?? 0 }

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

            // The acoustic passage of the hint depends only on the sound, and
            // recognition - only from him. They have nothing in common
            // so the pass starts here and goes parallel to parsing, and not
            // after it: previously these two jobs were queued one after the other
            // and the person was waiting for their amount. Gain measurement is in `docs/benchmarks.md`.
            async let spotted = Self.spotKeywords(samples: samples, helper: helper)

            // Each dictation is independent - we start with a clean decoder state.
            var state = try TdtDecoderState()
            // nil - auto-detection by sound. The model covers 25 European
            // languages; a hard choice breaks mixed speech, so the hint is
            // only explicit human choice when emphasis is shifted away from autodetection.
            let result = try await manager.transcribe(
                samples,
                decoderState: &state,
                language: language
            )
            decoderState = state
            // The prompter edits the text based on the acoustic evidence of the CTC model.
            // Timings remain from the original tokens: replacing a word does not move
            // its place in the recording, and consumers of word-by-word timings, which
            // the letter-by-letter accuracy of the replaced word is important, it is not in the product.
            text = Self.rescore(
                text: result.text,
                timings: result.tokenTimings,
                spotted: try await spotted,
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
    ) async throws -> CtcKeywordSpotter.SpotKeywordsResult? {
        guard let helper else { return nil }
        return try await helper.spotter.spotKeywordsWithLogProbs(
            audioSamples: samples,
            customVocabulary: helper.context,
            minScore: nil
        )
    }

    /// Correct the text based on already obtained acoustic evidence.
    ///
    /// Returns `nil` when the hint is not configured or there is nothing to change.
    private static func rescore(
        text: String,
        timings: [TokenTiming]?,
        spotted: CtcKeywordSpotter.SpotKeywordsResult?,
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
