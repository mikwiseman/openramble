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

    /// `threadCount` of zero asks the runtime for its own default.
    public init(backend: Backend = .metal, threadCount: Int32 = 0) {
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
                guard let message,
                      level == TRANSCRIBE_LOG_LEVEL_WARN || level == TRANSCRIBE_LOG_LEVEL_ERROR
                else { return }
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

    public func transcribe(samples: [Float]) async throws -> DictationCore.ASRResult {
        try await transcribe(samples: samples, languageHint: nil)
    }

    /// Recognize one finished take.
    ///
    /// `languageHint` is a BCP-47 code, or `nil` to let the model decide. The
    /// product passes `nil`: this model spans 25 languages with one tokenizer
    /// and handles speech that switches between them mid-sentence, which a
    /// forced language cannot.
    public func transcribe(
        samples: [Float],
        languageHint: String?
    ) async throws -> DictationCore.ASRResult {
        guard let engine else { throw ASREngineError.modelsNotLoaded }
        let session = engine.session
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("empty buffer")
        }

        let started = ContinuousClock.now
        let audioDuration = Double(samples.count) / Double(Self.requiredSampleRate)

        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        params.task = TRANSCRIBE_TASK_TRANSCRIBE
        // Nothing in the product reads word or token timings — only the
        // benchmark tool ever did. Asking for them would buy alignment work
        // that is thrown away.
        params.timestamps = TRANSCRIBE_TIMESTAMPS_NONE

        let status = Self.withOptionalCString(languageHint) { language in
            params.language = language
            return transcribe_run(session, samples, Int32(samples.count), &params)
        }

        switch status {
        case TRANSCRIBE_OK:
            break
        case TRANSCRIBE_ERR_ABORTED:
            throw ASREngineError.cancelled
        default:
            throw ASREngineError.inferenceFailed(Self.describe(status))
        }

        // The returned pointer belongs to the session and is valid only until
        // the next run on it. Copying here, inside the actor, is what keeps
        // that lifetime from becoming the caller's problem.
        guard let text = transcribe_full_text(session) else {
            throw ASREngineError.inferenceFailed("the runtime returned no text")
        }

        return DictationCore.ASRResult(
            text: String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines),
            words: [],
            audioDuration: audioDuration,
            processingDuration: started.duration(to: .now).seconds
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
            samples: [Float](repeating: 0, count: Self.requiredSampleRate / 2),
            languageHint: nil
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

    /// Call `body` with a C string for `value`, or with `nil` when it is absent.
    ///
    /// `withCString` has no optional form, and the borrowed pointer must not
    /// outlive the call — which is exactly the mistake this exists to prevent.
    private static func withOptionalCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) throws -> T
    ) rethrows -> T {
        guard let value else { return try body(nil) }
        return try value.withCString { try body($0) }
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
