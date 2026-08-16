import DictationCore
import Foundation
import LocalASR

// Phase P0 tool: install the model, check it and measure recognition.
//
// Exists for the sake of the gate “the engine is selected on live speech, not on synthesis”: for now
// there is no application, this is the only way to run real records and get
// speed and memory numbers.

func usage() -> Never {
    print("""
    asr-bench - testing local recognition

    Teams:
      status what is installed and where
      install download and install the model (~483 MB)
      install-vocab download acoustic term hint (~103 MB)
      import <folder> take the model from the finished folder, without network
      delete delete installed model
      transcribe <file>... recognize files
      bench <file>... measure file decode + product recognition
      bench-predecoded <file>... decode once, then measure the in-memory product path
      serve-jsonl persistent benchmark protocol (JSONL on stdin/stdout)
      timings <file>... recognize and print word timings
      eval <manifest.json> run the body and calculate WER/CER

    Environment Variables:
      WAI_MODELS_ROOT installation root (Application Support default)
      WAI_VOCAB=on enable installed term hint
      WAI_VOCAB_DIR folder of CTC models of the prompter (for measurements)
      WAI_VOCAB_SIMILARITY prompt similarity threshold (default 0.65)
      WAI_VOCAB_TERMS leave the first N terms (measuring the price of the dictionary)
      WAI_EVAL_PIPELINE=on the scorer counts the text after the replacement dictionary
      WAI_ASR_MEL_CONTEXT=on return FluidAudio mel context at the window junction
                                (just to repeat speech loss measurement)
      WAI_ASR_MODEL_DIR engine bundle folder past storage (for measurements)
      WAI_ASR_ENCODER palettized6bit (default) | int4
      WAI_ASR_ENCODER_PLACEMENT automatic (default) | neuralEngine | gpu
      WAI_ASR_DUAL_DECODE=on second decoder pass with arbitration
      WAI_ASR_MAX_TOKENS ceiling of tokens per window (default: product value, 600)
      WAI_ASR_CHUNK_CONCURRENCY parallel long-form windows (default: product value, 4)
      WAI_ASR_VOCAB_SCHEDULING candidateRegions (TDT-first product default) | alwaysParallel
      WAI_ASR_LANGUAGE forced language (ru, en, ...) instead of auto
      WAI_ASR_PREWARM=on run the same inference warm-up as the shipping app
    """)
    exit(64)
}

func modelsRoot() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"] else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
}

func makeStore() throws -> (ModelStore, ModelInstallLayout, ModelManifest) {
    let manifest = try ModelManifest.bundled()
    let layout = try ModelInstallLayout(manifest: manifest, root: modelsRoot())
    let store = ModelStore(manifest: manifest, layout: layout)
    return (store, layout, manifest)
}

/// Acoustic hint storage - using the same mechanism as the main one:
/// recorded audit, check of amounts, crash-safe promotion.
func makeVocabularyStore() throws -> (ModelStore, ModelInstallLayout, ModelManifest) {
    let manifest = try ModelManifest.bundledVocabulary()
    let layout = try ModelInstallLayout(manifest: manifest, root: modelsRoot())
    let store = ModelStore(manifest: manifest, layout: layout)
    return (store, layout, manifest)
}

/// Downloading with progress is the common path for both models.
func install(store: ModelStore, layout: ModelInstallLayout, manifest: ModelManifest) async -> Never {
    print("Downloading \(formatBytes(manifest.totalByteCount)) - \(manifest.files.count) file(s)")
    print("Source: \(manifest.repository) @ \(manifest.revision)")

    let states = await store.states()
    let monitor = Task {
        var lastShown = -1
        for await state in states {
            switch state {
            case let .downloading(received, total) where total > 0:
                let percent = Int(Double(received) / Double(total) * 100)
                if percent >= lastShown + 5 {
                    lastShown = percent
                    print("  \(percent)% — \(formatBytes(received))")
                }
            case let .verifying(checked, total):
                print(" check \(checked)/\(total)")
            default:
                break
            }
        }
    }

    await store.install()
    monitor.cancel()

    let finalState = await store.currentState()
    printState(finalState, layout: layout, manifest: manifest)
    exit(finalState.isReady ? 0 : 70)
}

func formatBytes(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_000_000)
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Peak process memory - for the “model fits into memory” gate.
func peakMemoryBytes() -> Int64 {
    var info = rusage()
    guard getrusage(RUSAGE_SELF, &info) == 0 else { return 0 }
    // On Apple platforms, ru_maxrss is given in bytes.
    return Int64(info.ru_maxrss)
}

func printState(_ state: ModelState, layout: ModelInstallLayout, manifest: ModelManifest) {
    switch state {
    case .notInstalled:
        print("Model not installed.")
        print("Will download: \(formatBytes(manifest.totalByteCount)) in \(layout.installedDirectory.path)")
    case let .downloading(received, total):
        print("Loading: \(formatBytes(received)) from \(formatBytes(total))")
    case let .verifying(checked, total):
        print("Checking: \(checked) from \(total)")
    case let .ready(directory):
        print("Model ready: \(directory.path)")
        print("Revision: \(manifest.revision)")
        print("Files: \(manifest.files.count), \(formatBytes(manifest.totalByteCount))")
    case let .repairRequired(detail):
        print("Model requires recovery: \(detail)")
    case let .failed(error):
        print("Error: \(error)")
    case .deleting:
        print("Deleting...")
    }
}

func isOn(_ name: String) -> Bool {
    ProcessInfo.processInfo.environment[name]?.lowercased() == "on"
}

func prepareTranscriber(
    performConfiguredWarmup: Bool = true,
    collectPhaseTimings: Bool = false,
    logger: @escaping (String) -> Void = { print($0) }
) async throws -> LocalTranscriber {
    // An explicit bundle folder is the only way to compare two encoders: storage
    // checks the installation against the manifest and rightly rejects the extra file
    // (`EncoderInt4.mlmodelc` is not included in the manifest). The same technique has already been applied to
    // to the prompter via `WAI_VOCAB_DIR`.
    let explicitModelDirectory = ProcessInfo.processInfo.environment["WAI_ASR_MODEL_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    let engineDirectory: URL
    if let explicitModelDirectory {
        logger("The engine folder is specified explicitly: \(explicitModelDirectory.path) (frozen, past the storage)")
        engineDirectory = explicitModelDirectory
    } else {
        let (store, layout, _) = try makeStore()
        let state = await store.refreshState()
        guard state.isReady else {
            logger("The model is not installed. Run: asr-bench install")
            exit(69)
        }
        engineDirectory = layout.engineDirectory
    }

    // The switch exists for the sake of measurement repeatability: it was he who showed
    // that the text at the junction of windows loses the included mel-context, and not the length of the piece.
    let melChunkContext = isOn("WAI_ASR_MEL_CONTEXT")
    if melChunkContext { logger("Mel context at the window junction is enabled (measuring, not working mode)") }

    // Engine handles. Unknown value is a visible error, not a silent fallback to
    // default: otherwise the measurement would silently measure something other than what is written in the command.
    let encoder: EncoderVariant
    if let raw = ProcessInfo.processInfo.environment["WAI_ASR_ENCODER"] {
        guard let parsed = EncoderVariant(rawValue: raw) else {
            logger("WAI_ASR_ENCODER: unknown option '\(raw)'")
            exit(64)
        }
        encoder = parsed
        logger("Encoder: \(raw)")
    } else {
        encoder = .palettized6bit
    }

    let placement: EncoderPlacement
    if let raw = ProcessInfo.processInfo.environment["WAI_ASR_ENCODER_PLACEMENT"] {
        guard let parsed = EncoderPlacement(rawValue: raw) else {
            logger("WAI_ASR_ENCODER_PLACEMENT: unknown value '\(raw)'")
            exit(64)
        }
        placement = parsed
        logger("Encoder counts to: \(raw)")
    } else {
        // The product default. Explicit lanes remain available for host-local
        // calibration without hard-coding one Apple SoC's result.
        placement = .automatic
    }

    let dualDecode = isOn("WAI_ASR_DUAL_DECODE")
    if dualDecode { logger("Second pass decoder with arbitration enabled") }

    // The token ceiling is not duplicated by a number here: the default lives in the adapter,
    // and the bench must measure exactly what is in the product. Variable only
    // redefines it - for example, to repeat the measurement at the previous 150.
    var maxTokens: Int?
    if let raw = ProcessInfo.processInfo.environment["WAI_ASR_MAX_TOKENS"] {
        guard let parsed = Int(raw), parsed > 0 else {
            logger("WAI_ASR_MAX_TOKENS: expected a positive number, received '\(raw)'")
            exit(64)
        }
        maxTokens = parsed
        logger("Token ceiling per window: \(parsed)")
    }

    var chunkConcurrency: Int?
    if let raw = ProcessInfo.processInfo.environment["WAI_ASR_CHUNK_CONCURRENCY"] {
        guard let parsed = Int(raw), parsed > 0 else {
            logger("WAI_ASR_CHUNK_CONCURRENCY: expected a positive number, received '\(raw)'")
            exit(64)
        }
        chunkConcurrency = parsed
        logger("Parallel long-form windows: \(parsed)")
    }

    let vocabularyScheduling: VocabularyInferenceScheduling
    if let raw = ProcessInfo.processInfo.environment["WAI_ASR_VOCAB_SCHEDULING"] {
        guard let parsed = VocabularyInferenceScheduling(rawValue: raw) else {
            logger("WAI_ASR_VOCAB_SCHEDULING: unknown value '\(raw)'")
            exit(64)
        }
        vocabularyScheduling = parsed
    } else {
        vocabularyScheduling = .candidateRegions
    }
    logger("Vocabulary inference scheduling: \(vocabularyScheduling.rawValue)")

    let adapter = FluidAudioAdapter(
        melChunkContext: melChunkContext,
        encoder: encoder,
        encoderPlacement: placement,
        dualDecodeArbitration: dualDecode,
        maxTokensPerChunk: maxTokens ?? FluidAudioAdapter.defaultMaxTokensPerChunk,
        parallelChunkConcurrency: chunkConcurrency ?? FluidAudioAdapter.defaultParallelChunkConcurrency,
        vocabularyScheduling: vocabularyScheduling,
        collectPhaseTimings: collectPhaseTimings
    )
    let transcriber = LocalTranscriber(engine: adapter)
    let started = ContinuousClock.now
    try await transcriber.prepare(modelDirectory: engineDirectory)
    logger(String(format: "Model loaded in %.2f s", seconds(started.duration(to: .now))))

    // Acoustic term hint: comparison “with him and without him” - exactly
    // the measurement for which the switch exists. `WAI_VOCAB=on` takes
    // installed prompt (install-vocab); `WAI_VOCAB_DIR` - explicit folder.
    var vocabularyDirectory = ProcessInfo.processInfo.environment["WAI_VOCAB_DIR"]
    if vocabularyDirectory == nil, isOn("WAI_VOCAB") {
        let (vocabStore, vocabLayout, _) = try makeVocabularyStore()
        guard await vocabStore.refreshState().isReady else {
            logger("Prompt is not installed. Run: asr-bench install-vocab")
            exit(69)
        }
        vocabularyDirectory = vocabLayout.engineDirectory.path
    }
    if let vocabDirectory = vocabularyDirectory {
        let similarity = ProcessInfo.processInfo.environment["WAI_VOCAB_SIMILARITY"]
            .flatMap(Float.init)
        let biasWeight = ProcessInfo.processInfo.environment["WAI_VOCAB_CBW"]
            .flatMap(Float.init)
        let defaults = VocabularyBoost.developerDefault()
        // Trimming the list exists for the sake of one question: the price of the hint
        // grows from the number of terms or from the length of the record? The answer decides whether there is
        // it makes sense to narrow the dictionary for the sake of speed.
        var terms = defaults.terms
        if let raw = ProcessInfo.processInfo.environment["WAI_VOCAB_TERMS"] {
            guard let limit = Int(raw), limit > 0 else {
                logger("WAI_VOCAB_TERMS: expected a positive number, received '\(raw)'")
                exit(64)
            }
            terms = Array(terms.prefix(limit))
            logger("Terms left: \(terms.count)")
        }
        let boost = VocabularyBoost(
            terms: terms,
            minSimilarity: similarity ?? defaults.minSimilarity,
            biasWeight: biasWeight ?? defaults.biasWeight
        )
        if let similarity {
            logger("Suggestion similarity threshold: \(similarity) (WAI_VOCAB_SIMILARITY)")
        }
        if let biasWeight {
            logger("Acoustic evidence weight: \(biasWeight) (WAI_VOCAB_CBW)")
        }
        let vocabStarted = ContinuousClock.now
        try await transcriber.prepareVocabulary(
            modelDirectory: URL(fileURLWithPath: vocabDirectory, isDirectory: true),
            boost: boost
        )
        logger(
            String(
                format: "Prompt loaded in %.2f with - %d terms",
                seconds(vocabStarted.duration(to: .now)),
                boost.terms.count
            )
        )
    }
    if performConfiguredWarmup, isOn("WAI_ASR_PREWARM") {
        let warmupStarted = ContinuousClock.now
        try await transcriber.warmUpInference()
        logger(
            String(
                format: "Inference warmed in %.2f s",
                seconds(warmupStarted.duration(to: .now))
            )
        )
    }
    return transcriber
}

/// The application's replacement dictionary on top of the raw response is what a person sees.
///
/// `WAI_EVAL_PIPELINE=on` is turned on. Allows you to compare not engines, but
/// product: the raw answer is printed next to it, the scorer counts the processed one.
func makeEvalPipeline() -> TextPipeline? {
    let mode = ProcessInfo.processInfo.environment["WAI_EVAL_PIPELINE"]?.lowercased()
    switch mode {
    case "on":
        print("The scorer counts the text after the replacement dictionary (WAI_EVAL_PIPELINE=on)")
        return TextPipeline(replacements: StarterDictionary.developer)
    case "exact":
        print("Dictionary without phonetic selection (WAI_EVAL_PIPELINE=exact)")
        return TextPipeline(replacements: StarterDictionary.developer, phoneticMatching: false)
    default:
        return nil
    }
}

/// Forced language instead of autodetection - exactly what a person chooses
/// in settings. There is so that the hypothesis “hard language helps” can be
/// check by running, not by discussing.
func languageHint() -> String? {
    guard let raw = ProcessInfo.processInfo.environment["WAI_ASR_LANGUAGE"] else { return nil }
    guard FluidAudioAdapter.supportedLanguageHints.contains(raw) else {
        print("WAI_ASR_LANGUAGE: unsupported language '\(raw)'")
        exit(64)
    }
    print("Force language: \(raw)")
    return raw
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let operands = Array(arguments.dropFirst())

switch command {
case "serve-jsonl":
    guard operands.isEmpty else { usage() }
    exit(await BenchmarkJSONLServer.run())

case "status":
    let (store, layout, manifest) = try makeStore()
    let state = await store.refreshState()
    printState(state, layout: layout, manifest: manifest)
    let (vocabStore, vocabLayout, vocabManifest) = try makeVocabularyStore()
    let vocabState = await vocabStore.refreshState()
    print("\nTerm Tip:")
    printState(vocabState, layout: vocabLayout, manifest: vocabManifest)
    exit(state.isReady ? 0 : 69)

case "install":
    let (store, layout, manifest) = try makeStore()
    if await store.refreshState().isReady {
        print("Model already installed: \(layout.installedDirectory.path)")
        exit(0)
    }
    await install(store: store, layout: layout, manifest: manifest)

case "install-vocab":
    let (store, layout, manifest) = try makeVocabularyStore()
    if await store.refreshState().isReady {
        print("Prompt is already installed: \(layout.installedDirectory.path)")
        exit(0)
    }
    await install(store: store, layout: layout, manifest: manifest)

case "import":
    guard let sourcePath = operands.first else { usage() }
    let (store, layout, manifest) = try makeStore()
    if await store.refreshState().isReady {
        print("Model already installed: \(layout.installedDirectory.path)")
        exit(0)
    }

    let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
    print("I take the model from \(source.path)")
    print("I will check all \(manifest.files.count) checksums - the source of trust does not change")

    await store.importModel(from: source)
    let importedState = await store.currentState()
    printState(importedState, layout: layout, manifest: manifest)
    exit(importedState.isReady ? 0 : 70)

case "delete":
    let (store, layout, _) = try makeStore()
    await store.delete()
    print("Deleted: \(layout.modelDirectory.path)")
    let (vocabStore, vocabLayout, _) = try makeVocabularyStore()
    await vocabStore.delete()
    print("Deleted: \(vocabLayout.modelDirectory.path)")

case "eval":
    guard let manifestPath = operands.first else { usage() }
    let items = try Evaluation.loadManifest(at: manifestPath)
    let transcriber = try await prepareTranscriber()
    let pipeline = makeEvalPipeline()
    let language = languageHint()

    var outcomes: [EvalOutcome] = []
    for item in items {
        let started = ContinuousClock.now
        let result: ASRResult
        do {
            result = try await transcriber.transcribe(
                fileURL: URL(fileURLWithPath: item.file),
                languageHint: language
            )
        } catch {
            print("\n=== \(URL(fileURLWithPath: item.file).lastPathComponent) ===")
            print("Error: \(error)")
            continue
        }
        let hypothesis = pipeline.map { $0.process(result.text).text } ?? result.text
        let outcome = EvalOutcome(
            item: item,
            report: TranscriptScorer.score(reference: item.reference, hypothesis: hypothesis),
            result: result,
            wallClock: seconds(started.duration(to: .now)),
            peakMemory: peakMemoryBytes()
        )
        outcomes.append(outcome)
        print(Evaluation.describe(outcome, showDifferences: true))
        fflush(stdout)
    }

    print(Evaluation.summary(outcomes))
    print("\nprocess peak memory: \(formatBytes(peakMemoryBytes()))")

case "timings":
    guard !operands.isEmpty else { usage() }
    let transcriber = try await prepareTranscriber()
    for path in operands {
        let result = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: path))
        print("\n=== \(URL(fileURLWithPath: path).lastPathComponent) ===")
        print(String(format: "audio %.2f s, words %d", result.audioDuration, result.words.count))
        for word in result.words {
            print(String(format: "%8.2f %8.2f  %@", word.start, word.end, word.text))
        }
    }

case "transcribe", "bench", "bench-predecoded":
    guard !operands.isEmpty else { usage() }
    let transcriber = try await prepareTranscriber()
    let measure = command != "transcribe"
    let predecoded = command == "bench-predecoded"
    let language = languageHint()
    let reader = AudioFileReader()
    var decodedByPath: [String: [Float]] = [:]

    if predecoded {
        // Handy's file benchmark decodes WAV before its timer, and live
        // dictation in both products already owns PCM. Keep this lane explicit
        // so file-wall numbers cannot be mistaken for engine/product numbers.
        for path in Set(operands) {
            decodedByPath[path] = try reader.samples(from: URL(fileURLWithPath: path))
        }
        print("Benchmark lane: predecoded in-memory product path")
    }

    for path in operands {
        let url = URL(fileURLWithPath: path)
        let started = ContinuousClock.now
        do {
            let result: ASRResult
            if let samples = decodedByPath[path] {
                result = try await transcriber.transcribe(samples: samples, languageHint: language)
            } else {
                result = try await transcriber.transcribe(fileURL: url, languageHint: language)
            }
            let wall = seconds(started.duration(to: .now))

            print("\n=== \(url.lastPathComponent) ===")
            print(result.text)

            if measure {
                let realtimeFactor = wall > 0 ? result.audioDuration / wall : 0
                print("---")
                print(String(format: "audio: %.2f s", result.audioDuration))
                // Four decimals keep the short-utterance distribution usable
                // for p50/p95 comparisons; two decimals quantized away most of
                // the difference between fast local pipelines.
                print(String(format: "recognized: %.4f s", wall))
                print(String(format: "%.1f times faster than real time", realtimeFactor))
                print("words with timings: \(result.words.count)")
                print("peak memory: \(formatBytes(peakMemoryBytes()))")
            }
        } catch {
            print("\n=== \(url.lastPathComponent) ===")
            print("Error: \(error)")
            exit(70)
        }
    }

default:
    usage()
}
