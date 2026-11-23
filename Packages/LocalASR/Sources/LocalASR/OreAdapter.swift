import DictationCore
import Foundation
import ORE

/// The recognizer for Intel Macs: OpenRamble's own engine in `engine/`.
///
/// One of the two files that may talk to a recognition engine; the other is
/// `TranscribeCppAdapter`, which runs Apple silicon on Metal. An Intel Mac has
/// no Metal path in either engine, so recognition runs on the processor, and
/// there this engine is about twice as fast as transcribe.cpp on the same four
/// threads (research/own-engine-2026-11, the ledger's speed tables).
///
/// It gives the same words: the engine follows transcribe.cpp's arithmetic,
/// its long-audio cutting and its treatment of taught words, and the ledger
/// records the comparison clip by clip.
public actor OreAdapter: BatchASREngineAdapting {
    public static var engineVersion: String { String(cString: ore_version()) }

    /// Owns the two C pointers and frees them in order: the session before
    /// the model it reads.
    private final class Engine: @unchecked Sendable {
        let model: OpaquePointer
        let session: OpaquePointer
        /// One run at a time, on a thread of this engine's own and never on
        /// Swift's cooperative pool, for the reasons `TranscribeCppAdapter`
        /// gives.
        let queue = DispatchQueue(label: "is.waiwai.dictation.ore-run", qos: .userInteractive)
        /// The terms the session was last given. Read and written only on
        /// `queue`.
        var appliedVocabulary: [String] = []

        init(model: OpaquePointer, session: OpaquePointer) {
            self.model = model
            self.session = session
        }

        deinit {
            ore_session_close(session)
            ore_model_close(model)
        }
    }

    private var engine: Engine?
    private var loadedDirectory: URL?
    private let threadCount: Int32
    private var vocabulary: [String] = []

    /// `threadCount` of zero lets the engine choose: as many threads as the
    /// Mac has processors, at most four, which is what the Intel build has
    /// always used. The engine's threads never wait for one another, so a
    /// busy Mac slows a recognition down without stalling it.
    public init(threadCount: Int32 = 0) {
        self.threadCount = threadCount
    }

    /// Words the decoder leans toward, in priority order. The decoder
    /// completes one of these spellings once the model has begun it on its
    /// own; it never starts one. With no terms a run is what it was.
    public func setVocabulary(_ terms: [String]) {
        vocabulary = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: - Lifecycle

    /// Load the model from a prepared directory. Idempotent.
    public func loadModels(from directory: URL) async throws {
        if engine != nil, loadedDirectory == directory { return }
        if engine != nil { await unload() }

        let weights = try TranscribeCppAdapter.modelFile(in: directory)
        var reason: UnsafePointer<CChar>?
        guard let model = weights.path.withCString({ ore_model_open($0, &reason) }) else {
            throw ASREngineError.modelsUnavailable(reason.map { String(cString: $0) } ?? "the model file could not be opened")
        }
        guard let session = ore_session_open(model, threadCount) else {
            ore_model_close(model)
            throw ASREngineError.modelsUnavailable("not enough memory to start the recognizer")
        }
        engine = Engine(model: model, session: session)
        loadedDirectory = directory
    }

    /// Give the weights back. The handle's `deinit` does the freeing, in order.
    public func unload() async {
        engine = nil
        loadedDirectory = nil
    }

    public var isLoaded: Bool { engine != nil }

    /// The kernel set the engine chose for this processor: "avx2" on every
    /// Intel Mac this app runs on, "sse" under Rosetta.
    public var kernels: String? {
        guard let engine else { return nil }
        return String(cString: ore_session_kernels(engine.session))
    }

    // MARK: - Recognition

    public func transcribe(samples: [Float]) async throws -> ASRResult {
        try await transcribe(samples: samples, timestamps: false)
    }

    public func transcribe(samples: [Float], timestamps: Bool) async throws -> ASRResult {
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("empty buffer")
        }
        let results = try await run([samples], timestamps: timestamps, cancellation: Cancellation())
        try Task.checkCancellation()
        return try results[0].get()
    }

    /// The clips of a batch are recognized one after another. On a processor
    /// that costs nothing: one clip already uses every thread.
    public func transcribe(
        batch: [[Float]],
        timestamps: Bool = false,
        shouldYield: @escaping @Sendable () -> Bool = { false }
    ) async throws -> [Result<ASRResult, ASREngineError>] {
        try Task.checkCancellation()
        guard !batch.isEmpty, batch.count <= 8,
              batch.allSatisfy({ !$0.isEmpty && $0.count <= Int(Int32.max) }) else {
            throw ASREngineError.unsupportedAudioFormat("expected 1–8 nonempty audio buffers")
        }
        let results = try await run(batch, timestamps: timestamps, cancellation: Cancellation(shouldYield: shouldYield))
        try Task.checkCancellation()
        return results
    }

    private func run(
        _ clips: [[Float]], timestamps: Bool, cancellation: Cancellation
    ) async throws -> [Result<ASRResult, ASREngineError>] {
        guard let engine else { throw ASREngineError.modelsNotLoaded }
        let vocabulary = vocabulary
        let started = ContinuousClock.now
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                engine.queue.async {
                    let results = Self.recognize(
                        clips, on: engine, vocabulary: vocabulary, timestamps: timestamps,
                        cancellation: cancellation, queuedAt: started
                    )
                    // Held to here: the pointers carry no ownership, and
                    // `unload()` must not free the session under a run.
                    withExtendedLifetime(engine) {}
                    continuation.resume(returning: results)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// One whole run-and-read per clip, on the engine's thread. Results are
    /// copied before the next run, which clears them.
    private static func recognize(
        _ clips: [[Float]], on engine: Engine, vocabulary: [String], timestamps: Bool,
        cancellation: Cancellation, queuedAt: ContinuousClock.Instant
    ) -> [Result<ASRResult, ASREngineError>] {
        let session = engine.session
        if engine.appliedVocabulary != vocabulary {
            let copies = vocabulary.map { strdup($0) }
            defer { copies.forEach { free($0) } }
            let pointers: [UnsafePointer<CChar>?] = copies.map { UnsafePointer($0) }
            guard ore_session_set_vocabulary(session, pointers, Int32(pointers.count)) == ORE_OK else {
                return clips.map { _ in .failure(.inferenceFailed("not enough memory for the taught words")) }
            }
            engine.appliedVocabulary = vocabulary
        }

        ore_session_set_abort(session, { context in
            guard let context else { return 0 }
            return Unmanaged<Cancellation>.fromOpaque(context).takeUnretainedValue().shouldAbort ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer {
            ore_session_set_abort(session, nil, nil)
            withExtendedLifetime(cancellation) {}
        }

        return clips.map { clip in
            guard !cancellation.shouldAbort else { return .failure(.cancelled) }
            // A short clip is padded with silence at its end, as it is for
            // the other engine and on the other platforms: the front end
            // needs more than a few frames. The reported length stays the
            // real one.
            let duration = Double(clip.count) / Double(TranscribeCppAdapter.requiredSampleRate)
            let minimum = TranscribeCppAdapter.minimumEngineSamples
            let padded = clip.count >= minimum ? clip : clip + [Float](repeating: 0, count: minimum - clip.count)

            let runStarted = ContinuousClock.now
            let status = ore_run(session, padded, Int32(padded.count))
            let elapsed = runStarted.duration(to: .now).seconds
            switch status {
            case ORE_OK:
                break
            case ORE_ERR_ABORTED:
                return .failure(.cancelled)
            case ORE_ERR_MEMORY:
                return .failure(.inferenceFailed("not enough memory", code: Int(status.rawValue)))
            default:
                return .failure(.inferenceFailed("the model cannot take this clip", code: Int(status.rawValue)))
            }
            return .success(ASRResult(
                text: String(cString: ore_text(session)).trimmingCharacters(in: .whitespacesAndNewlines),
                words: timestamps ? words(of: session, duration: duration) : [],
                audioDuration: duration,
                processingDuration: elapsed,
                engineDispatchDuration: max(0, queuedAt.duration(to: .now).seconds - elapsed)
            ))
        }
    }

    private static func words(of session: OpaquePointer, duration: Double) -> [ASRResult.Word] {
        (0..<ore_word_count(session)).compactMap { index in
            var word = ore_word()
            guard ore_word_at(session, index, &word) != 0, let text = word.text else { return nil }
            let start = min(duration, max(0, Double(word.t0_ms) / 1000))
            return ASRResult.Word(text: String(cString: text), start: start,
                                  end: min(duration, max(start, Double(word.t1_ms) / 1000)))
        }
    }

    /// The engine's abort callback reads only this synchronized state.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let shouldYield: @Sendable () -> Bool

        init(shouldYield: @escaping @Sendable () -> Bool = { false }) {
            self.shouldYield = shouldYield
        }

        var shouldAbort: Bool { lock.withLock { cancelled } || shouldYield() }
        func cancel() { lock.withLock { cancelled = true } }
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
