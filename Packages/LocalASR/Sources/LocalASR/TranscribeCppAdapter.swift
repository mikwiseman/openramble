import CTranscribe
import DictationCore
import Foundation
import os

private let runtimeLog = Logger(subsystem: "is.waiwai.dictation", category: "asr-runtime")

/// The only place in the project that talks to the transcribe.cpp runtime.
///
/// Everything else — the dictation controller, the app, the tests — works
/// through `ASREngineAdapting`, exactly as it did for the Core ML engine this
/// replaces. Confining the C API to one file is what made that replacement a
/// contained change rather than a rewrite, and it is what would make the next
/// one contained too.
///
/// Why this engine at all: the Core ML path spent its time not on inference but
/// on Neural Engine program specialization, cached by the OS in
/// `com.apple.e5rt.e5bundlecache` — a cache macOS purges precisely when memory
/// is short. Rebuilding it cost 13.5–16 s, so the engine was at its slowest
/// exactly when the machine was already struggling, and a 2.4 GB resident set
/// made that struggle more likely. This runtime compiles nothing at load: the
/// weights are data, the backend is Metal, and a reload is a file read.
public actor TranscribeCppAdapter: ASREngineAdapting {
    /// Sample rate the runtime requires. The recorder already produces this, so
    /// nothing resamples on the way in.
    public static let requiredSampleRate = 16_000

    /// The shortest clip the mel front-end will accept without producing NaNs:
    /// 1.25 seconds, the same constant as `MINIMUM_ENGINE_SAMPLES` in
    /// `core/ramble-audio/src/prepare.rs`. The two must move together.
    public static let minimumEngineSamples = requiredSampleRate * 5 / 4

    /// The loaded runtime, or nothing.
    ///
    /// Both pointers live in one handle so that releasing them is a single
    /// assignment with no order to get wrong at the call site.
    private var engine: Engine?
    private var loadedDirectory: URL?

    /// Owns the two C pointers and frees them in the one correct order.
    ///
    /// Sessions first, then the model. This is not stylistic: the runtime
    /// requires every session to be gone before its model, and a Metal
    /// residency set torn down out of order aborts the process instead of
    /// returning an error — a failure this project has already watched happen
    /// once, on an error path in an earlier experiment with a related runtime.
    /// Putting it in `deinit` means the rule holds even on paths nobody wrote
    /// deliberately, which is where that abort came from.
    private final class Engine: @unchecked Sendable {
        let model: OpaquePointer
        let session: OpaquePointer

        init(model: OpaquePointer, session: OpaquePointer) {
            self.model = model
            self.session = session
        }

        deinit {
            transcribe_session_free(session)
            transcribe_model_free(model)
        }
    }

    private let backend: Backend
    private let threadCount: Int32

    /// Where inference runs.
    ///
    /// Pinned rather than automatic, deliberately. The previous engine let the
    /// OS choose per load, which meant the same dictation could take a
    /// different path depending on what else on the Mac wanted the accelerator
    /// — the same recording, two very different latencies, no way to explain
    /// it to the person waiting. A fixed backend is slightly slower in the best
    /// case and enormously more predictable in every other one.
    public enum Backend: Sendable {
        case metal
        case cpu

        var request: transcribe_backend_request {
            switch self {
            case .metal: TRANSCRIBE_BACKEND_METAL
            case .cpu: TRANSCRIBE_BACKEND_CPU
            }
        }
    }

    /// One decoder thread is deliberate. Parakeet's CPU-side predictor uses a
    /// spin/yield barrier for every graph node as soon as `n_threads >= 2`.
    /// Under processor pressure the runtime default of eight made a four-second
    /// take 4–10× slower; one thread removes the barrier completely while the
    /// Metal encoder, Accelerate filterbank and mel front-end keep their own
    /// parallelism. The live pressure and long-audio gates document the trade.
    /// Re-evaluate before adopting the runtime's streaming API: unlike batch,
    /// its mel front-end also consumes this session thread count.
    public init(backend: Backend = .metal, threadCount: Int32 = 1) {
        self.backend = backend
        self.threadCount = threadCount
        Self.silenceRuntimeLogging()
    }

    /// Route the runtime's own logging away from the console.
    ///
    /// Left alone it narrates every Metal kernel it compiles and every decode
    /// it runs, straight to stderr. In a menu-bar app that is noise in the
    /// user's system log at best, and it is not the kind of noise anyone would
    /// think to look for. Warnings and errors are kept — at debug level, under
    /// the project's own subsystem, where they can be read deliberately.
    ///
    /// The sink is global to the library, so it is installed once. Nothing
    /// dictated reaches it: these are the runtime's own messages about kernels
    /// and shapes.
    private static let silenceRuntimeLogging: @Sendable () -> Void = {
        let install: Void = {
            transcribe_log_set({ level, message, _ in
                guard let message else { return }
                #if OPENRAMBLE_DIAGNOSTICS
                guard level == TRANSCRIBE_LOG_LEVEL_DEBUG
                    || level == TRANSCRIBE_LOG_LEVEL_WARN
                    || level == TRANSCRIBE_LOG_LEVEL_ERROR else { return }
                #else
                guard level == TRANSCRIBE_LOG_LEVEL_WARN
                    || level == TRANSCRIBE_LOG_LEVEL_ERROR else { return }
                #endif
                runtimeLog.debug("transcribe.cpp: \(String(cString: message), privacy: .public)")
            }, nil)
        }()
        return { _ = install }
    }()

    // MARK: - Lifecycle

    /// Load the model from a prepared directory. Idempotent.
    ///
    /// The directory holds exactly one GGUF file. Reading the directory rather
    /// than taking a file path keeps the installer's contract — "a verified
    /// revision lives here" — instead of spreading a filename through the app.
    public func loadModels(from directory: URL) async throws {
        if engine != nil, loadedDirectory == directory { return }
        if engine != nil { await unload() }

        let weights = try Self.modelFile(in: directory)

        var loadParams = transcribe_model_load_params()
        transcribe_model_load_params_init(&loadParams)
        loadParams.backend = backend.request

        var loaded: OpaquePointer?
        let loadStatus = weights.path.withCString { path in
            transcribe_model_load_file(path, &loadParams, &loaded)
        }
        guard loadStatus == TRANSCRIBE_OK, let loaded else {
            throw ASREngineError.modelsUnavailable(Self.describe(loadStatus))
        }

        var sessionParams = transcribe_session_params()
        transcribe_session_params_init(&sessionParams)
        sessionParams.n_threads = threadCount

        var opened: OpaquePointer?
        let sessionStatus = transcribe_session_init(loaded, &sessionParams, &opened)
        guard sessionStatus == TRANSCRIBE_OK, let opened else {
            transcribe_model_free(loaded)
            throw ASREngineError.modelsUnavailable(Self.describe(sessionStatus))
        }

        engine = Engine(model: loaded, session: opened)
        loadedDirectory = directory
    }

    /// Give the weights back. The handle's `deinit` does the freeing, in order.
    public func unload() async {
        engine = nil
        loadedDirectory = nil
    }

    /// Whether the engine is ready to recognize. For the owner's readiness UI.
    public var isLoaded: Bool { engine != nil }

    /// Which backend the runtime actually landed on.
    ///
    /// Asked rather than assumed: `Backend.metal` is a requirement, and a build
    /// without Metal would fail the load instead of quietly running on CPU, but
    /// a value that can be read should be read.
    public var activeBackend: String? {
        guard let engine, let name = transcribe_model_backend(engine.model) else { return nil }
        return String(cString: name)
    }

    // MARK: - Recognition

    /// Recognize one finished take.
    ///
    /// There is no language parameter, and this is where that was decided.
    /// `transcribe_run_params.language` exists in the runtime and, for this
    /// model family, changes nothing: `en`, `ru` and autodetection produced
    /// byte-identical transcripts of the same four recordings. An unknown code
    /// does have an effect — the run fails with
    /// `TRANSCRIBE_ERR_UNSUPPORTED_LANGUAGE` — so the field could only ever
    /// lose a dictation, never improve one.
    ///
    /// What the model does instead is choose one language for the whole decode
    /// and impose it on the entire take. Mixed speech is where that shows:
    /// English inside a Russian-dominant take comes back transliterated into
    /// Cyrillic, and Russian inside an English-dominant one is dropped without
    /// a trace. Two seconds of the other language is enough to tip it. The
    /// remedy is smaller decodes, not a hint.
    ///
    /// The engine cannot be asked which language it settled on, either.
    /// `transcribe_model_get_capabilities` reports `supports_language_detect`
    /// true and 25 languages for this model, yet `transcribe_detected_language`
    /// returns an empty string after every run on transcribe.cpp 0.2.0. That
    /// was measured, not assumed — a diagnostic was written against it and
    /// deleted. Check again before building anything on that accessor.
    public func transcribe(samples: [Float]) async throws -> DictationCore.ASRResult {
        guard let engine else { throw ASREngineError.modelsNotLoaded }
        // The session pointer is read on the engine thread, from the `Engine`
        // held across the hop — not copied out here, where nothing would keep
        // its owner alive.
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("empty buffer")
        }

        // Pad a short clip with silence, exactly as `ramble-audio` does on the
        // other platforms. Not a quality judgement: the mel front-end produces
        // NaNs when given fewer than two frames, and the Rust port has padded
        // for that reason since it was written. This side never did, so the
        // same recording could be recognised on Windows and produce nothing
        // here — a divergence the two implementations are required to close
        // together.
        //
        // The silence goes on the end, so nothing that was said is displaced.
        // The reported duration stays the real one: padding is a demand of the
        // front-end, not something the person spoke.
        let audioDuration = Double(samples.count) / Double(Self.requiredSampleRate)
        let samples = samples.count >= Self.minimumEngineSamples
            ? samples
            : samples + [Float](repeating: 0, count: Self.minimumEngineSamples - samples.count)

        let started = ContinuousClock.now

        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        params.task = TRANSCRIBE_TASK_TRANSCRIBE
        // Nothing in the product reads word or token timings — only the
        // benchmark tool ever did. Asking for them would buy alignment work
        // that is thrown away.
        params.timestamps = TRANSCRIBE_TIMESTAMPS_NONE

        // Run and read together, on a thread of this engine's own.
        //
        // `transcribe_run` is a synchronous C call that occupies its thread for
        // the whole inference. Running it on the actor means running it on
        // Swift's cooperative pool, where a blocked thread is lost rather than
        // yielded — measured on a busy Mac: 29.66 s waiting to reach an engine
        // that then worked for 1.31 s. Handy hands its engine call to a
        // blocking thread for the same reason.
        //
        // The result is read *inside* this block, and that is the whole
        // correctness of it. The runtime's header says the result pointer is
        // valid only until the next run on the session, and every run begins by
        // clearing the previous result. A previous attempt dispatched the run
        // but left the read on the actor: a second dictation then cleared the
        // first one's text before its owner read it, and the first came back
        // empty. `testScenario002` caught that and is the gate for this.
        //
        // The `Engine` object is captured, not the raw pointer, so `unload()`
        // cannot free the session underneath a run in progress. The pointer
        // carries no ownership of its own.
        // Params are rebuilt inside the block rather than captured: a C struct
        // is not `Sendable`.
        let timestamps = params.timestamps
        let task = params.task
        let outcome = await Self.runOnEngineThread(engine: engine) { session in
            var params = transcribe_run_params()
            transcribe_run_params_init(&params)
            params.task = task
            params.timestamps = timestamps
            let runtimeStarted = ContinuousClock.now
            let status = transcribe_run(session, samples, Int32(samples.count), &params)
            let runtimeDuration = runtimeStarted.duration(to: .now)
            guard status == TRANSCRIBE_OK else { return .failure(status, runtimeDuration) }
            // Copied before returning: past this block the pointer may be
            // cleared by the next run.
            return .success(String(cString: transcribe_full_text(session)), runtimeDuration)
        }

        let status: transcribe_status
        let rawText: String
        let runtimeDuration: Duration
        switch outcome {
        case let .failure(code, duration):
            status = code
            rawText = ""
            runtimeDuration = duration
        case let .success(text, duration):
            status = TRANSCRIBE_OK
            rawText = text
            runtimeDuration = duration
        }

        switch status {
        case TRANSCRIBE_OK:
            break
        case TRANSCRIBE_ERR_ABORTED:
            throw ASREngineError.cancelled
        default:
            throw ASREngineError.inferenceFailed(Self.describe(status))
        }

        // Empty is not an error here, however tempting it looks. Silence
        // legitimately recognises as nothing, and `testSilentRecordingProducesNoInsertion`
        // says so: an empty result must reach the caller as empty text, not as
        // a failure. Distinguishing "nobody spoke" from "a result was cleared"
        // cannot be done from the string, and inventing an error for both makes
        // the common case wrong to catch the rare one.
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        return DictationCore.ASRResult(
            text: trimmed,
            words: [],
            audioDuration: audioDuration,
            processingDuration: runtimeDuration.seconds,
            engineDispatchDuration: max(0, started.duration(to: .now).seconds - runtimeDuration.seconds)
        )
    }

    /// Run one tiny inference so the first real dictation is not the one that
    /// pays for whatever the runtime builds lazily.
    ///
    /// Measured on the previous engine, a first vocabulary-enabled recognition
    /// took 2.51 s against a 0.14 s steady state; the fix was the same then as
    /// now. Half a second of silence is enough and costs nothing anyone waits
    /// for, because it happens before the app reports itself ready.
    public func warmUpInference() async throws {
        guard engine != nil else { throw ASREngineError.modelsNotLoaded }
        _ = try await transcribe(
            samples: [Float](repeating: 0, count: Self.requiredSampleRate / 2)
        )
    }

    // MARK: - Helpers

    /// The single GGUF in a prepared revision directory.
    ///
    /// Fails loudly on none and on more than one. A directory holding two
    /// models is an installer bug, and picking one of them arbitrarily would
    /// turn that bug into a mysterious quality complaint months later.
    static func modelFile(in directory: URL) throws -> URL {
        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "gguf" }
        } catch {
            throw ASREngineError.modelsUnavailable("the model directory is unreadable")
        }
        switch candidates.count {
        case 1:
            return candidates[0]
        case 0:
            throw ASREngineError.modelsUnavailable("no model file in the installed revision")
        default:
            throw ASREngineError.modelsUnavailable(
                "the installed revision holds \(candidates.count) model files"
            )
        }
    }

    /// What a run produced, carried back as owned data.
    ///
    /// Never a pointer: the session may clear it the moment the next run
    /// starts, so nothing borrowed may cross this boundary.
    enum EngineOutcome: Sendable {
        case success(String, Duration)
        case failure(transcribe_status, Duration)
    }

    /// The one thread inference runs on.
    ///
    /// Serial, and this engine's alone. The runtime allows at most one run in
    /// flight per model across all sessions, which a serial queue gives for
    /// free; and it must not be shared with disk work, because sharing a queue
    /// with an `fsync` is what deadlocked the recording seal.
    private static let engineQueue = DispatchQueue(
        label: "is.waiwai.dictation.engine-run",
        // The same priority the dictation itself runs at. `userInitiated` cost
        // about a tenth of the engine's throughput in the latency benchmark —
        // the thread was being scheduled behind work the person is not waiting
        // for, which is the opposite of true here.
        qos: .userInteractive
    )

    /// Hand one whole run-and-read to the engine thread.
    ///
    /// The `Engine` is captured so its session cannot be freed mid-run.
    private static func runOnEngineThread(
        engine: Engine,
        _ work: @escaping @Sendable (OpaquePointer) -> EngineOutcome
    ) async -> EngineOutcome {
        await withCheckedContinuation { continuation in
            engineQueue.async {
                let outcome = work(engine.session)
                // Held to here explicitly: the pointer above carries no
                // ownership, and ARC could otherwise release the engine as
                // soon as its last use passed.
                withExtendedLifetime(engine) {}
                continuation.resume(returning: outcome)
            }
        }
    }

    private static func describe(_ status: transcribe_status) -> String {
        guard let text = transcribe_status_string(Int32(status.rawValue)) else {
            return "status \(status.rawValue)"
        }
        return String(cString: text)
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
