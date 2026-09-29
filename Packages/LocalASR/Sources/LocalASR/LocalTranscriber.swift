import DictationCore
import Foundation

/// Local speech recognition.
///
/// Keeps the model loaded, recognizes files and knows how to release memory.
///
/// The actor here protects the state, but **not** the order: actors are reentrant,
/// and on each `await` the next call is launched inside. The “one dictation” rule
/// at a time" is held by the state machine `DictationController` at a higher level - it
/// simply doesn't start the second one until the first one is finished. Here's to it
/// can't be relied upon: if someone calls `transcribe` twice, both are parsed
/// will go alternately, and it will be correct, but twice as slow.
public actor LocalTranscriber {
    private let engine: any ASREngineAdapting
    private let reader: AudioFileReader
    private var loadedDirectory: URL?
    /// The in-flight load, if any. Loads are single-flight: the press-time
    /// warm-up and the transcribe path both ask for the engine, and without
    /// coalescing they would start two multi-second model loads — doubling
    /// the memory spike on exactly the machine whose memory pressure caused
    /// the unload in the first place.
    private var loadTask: Task<Void, Error>?
    /// Bumped by every unload. A load that finishes into an older generation
    /// has been overtaken — its weights are released and its caller sees
    /// cancellation instead of a resurrected engine.
    private var generation = 0
    /// Recognition calls in flight. Residency's polite unload refuses while
    /// this is non-zero; only the forced unload (wedge recovery) ignores it.
    private var activeOperations = 0
    /// A silence inference that materializes Core ML/ANE execution state. It is
    /// single-flight, and a real dictation waits for it instead of competing for
    /// the same compute resources after the key is released.
    private var inferenceWarmupTask: Task<Void, Error>?
    /// Distinguishes successive warm-ups. A cancelled Core ML prediction may
    /// ignore cancellation and finish after unload plus a new prepare; its
    /// owner's defer must not clear the newer task's single-flight marker.
    private var inferenceWarmupEpoch = 0

    public init(
        engine: any ASREngineAdapting = TranscribeCppAdapter(),
        reader: AudioFileReader = AudioFileReader()
    ) {
        self.engine = engine
        self.reader = reader
    }

    public var isPrepared: Bool { loadedDirectory != nil }

    /// Is a recognition or load running right now?
    public var isBusy: Bool { activeOperations > 0 || loadTask != nil }

    /// A whole recording owns one residency, including the gaps between chunks.
    /// Forced unload invalidates the generation; no later chunk may use its replacement.
    func withPreparedModel<T: Sendable>(_ operation: @Sendable (Int) async throws -> T) async throws -> T {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }
        activeOperations += 1
        defer { activeOperations -= 1 }
        let expected = generation
        try Task.checkCancellation()
        if let inferenceWarmupTask { try await inferenceWarmupTask.value }
        try Task.checkCancellation()
        guard expected == generation, loadedDirectory != nil else { throw CancellationError() }
        let result = try await operation(expected)
        try Task.checkCancellation()
        guard expected == generation, loadedDirectory != nil else { throw CancellationError() }
        return result
    }

    func transcribeChunk(_ samples: [Float], generation expected: Int,
                         shouldYield: @escaping @Sendable () -> Bool) async throws -> [Result<ASRResult, ASREngineError>] {
        guard generation == expected else { throw CancellationError() }
        return try await transcribe(batch: [samples], timestamps: true, shouldYield: shouldYield)
    }

    public func transcribe(
        batch: [[Float]], timestamps: Bool = false,
        shouldYield: @escaping @Sendable () -> Bool = { false }
    ) async throws -> [Result<ASRResult, ASREngineError>] {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }
        guard let batchEngine = engine as? any BatchASREngineAdapting else {
            throw ASREngineError.inferenceFailed("this engine does not support native batches")
        }
        activeOperations += 1
        defer { activeOperations -= 1 }
        let expectedGeneration = generation
        try Task.checkCancellation()
        if let inferenceWarmupTask { try await inferenceWarmupTask.value }
        try Task.checkCancellation()
        guard generation == expectedGeneration, loadedDirectory != nil else { throw CancellationError() }
        let result = try await batchEngine.transcribe(batch: batch, timestamps: timestamps, shouldYield: shouldYield)
        try Task.checkCancellation()
        guard generation == expectedGeneration, loadedDirectory != nil else { throw CancellationError() }
        return result
    }

    /// Load the model in advance. Single-flight: concurrent calls ride one
    /// load. The first call after installation compiles the model for the
    /// neuromodule and is noticeably longer than subsequent ones — this
    /// should not happen at the moment the user is waiting for text.
    public func prepare(modelDirectory: URL) async throws {
        if loadedDirectory == modelDirectory { return }

        if let inFlight = loadTask {
            try await inFlight.value
            // The shared task marks completion before finishing, so by the
            // time any rider resumes, the mark is already visible.
            if loadedDirectory == modelDirectory { return }
        }

        let expectedGeneration = generation
        let engine = engine
        // The completion mark is set INSIDE the shared task (which inherits
        // this actor's isolation): riders may resume before the creator, and
        // marking outside the task would let a rider observe "not loaded"
        // and start a second multi-second load.
        let task = Task {
            try await engine.loadModels(from: modelDirectory)
            guard self.generation == expectedGeneration else {
                // Unloaded while loading: the owner has discarded this
                // generation. Release the orphaned weights and report the
                // load as overtaken, not successful.
                await engine.unload()
                throw CancellationError()
            }
            self.loadedDirectory = modelDirectory
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    /// The one thread allowed to wait on a recording file.
    ///
    /// Same rule as the audio teardown and the `fsync`: work that blocks on a
    /// disk gets a thread of its own, never a cooperative-pool one.
    private static let diskQueue = DispatchQueue(
        label: "is.waiwai.dictation.transcriber-disk",
        qos: .userInitiated
    )

    static func onDisk<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            diskQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Recognize the recorded file.
    public func transcribe(fileURL: URL) async throws -> ASRResult {
        let arrived = ContinuousClock.now
        let supportsTimedChunks = engine is any BatchASREngineAdapting
        let reader = reader
        do {
            return try await withPreparedModel { generation in
                let decodeStarted = ContinuousClock.now
                let chunks = supportsTimedChunks ? try await FileAudioChunks(url: fileURL) : nil
                if let chunks, chunks.duration > 30 {
                    let transcript = try await FileTranscriber(transcriber: self)
                        .transcribe(chunks: chunks, generation: generation)
                    return Self.result(transcript, since: arrived)
                }
                let samples: [Float]
                if let chunks {
                    samples = try await chunks.next()?.samples ?? []
                } else {
                    samples = try await Self.onDisk { try reader.samples(from: fileURL) }
                }
                let decoded = Self.seconds(decodeStarted.duration(to: .now))
                let result = try await self.transcribe(samples: samples)
                return ASRResult(text: result.text, words: result.words,
                    audioDuration: result.audioDuration, processingDuration: result.processingDuration,
                    engineDispatchDuration: result.engineDispatchDuration,
                    queueingDuration: max(0, Self.seconds(arrived.duration(to: .now))
                        - result.processingDuration - result.engineDispatchDuration),
                    decodingDuration: decoded, phaseTimings: result.phaseTimings)
            }
        } catch let failure as AudioFileReader.Failure {
            throw ASREngineError.unsupportedAudioFormat(String(describing: failure))
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func result(_ transcript: FileTranscript, since start: ContinuousClock.Instant) -> ASRResult {
        ASRResult(text: transcript.text, words: transcript.words, audioDuration: transcript.duration,
            processingDuration: transcript.recognitionSeconds,
            engineDispatchDuration: transcript.dispatchSeconds,
            queueingDuration: max(0, seconds(start.duration(to: .now))
                - transcript.recognitionSeconds - transcript.dispatchSeconds),
            decodingDuration: transcript.decodingSeconds)
    }

    /// Recognize a ready buffer.
    ///
    /// Parakeet does not split long inputs internally. Reuse the file pipeline's
    /// bounded windows and timestamp seams; ordinary short dictations stay direct.
    public func transcribe(samples: [Float]) async throws -> ASRResult {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("empty recording")
        }
        // Stamped at the door, before any waiting. Everything between here and
        // the engine actor — a queued continuation, a thread the cooperative
        // pool has not handed out, another dictation holding the actor — used
        // to be reported nowhere at all, and that interval is where every
        // stall this app has had actually lived.
        let arrived = ContinuousClock.now

        // Base-only adapters may omit word timestamps entirely. Preserve their
        // original direct contract; the shipping adapter supports timed chunks.
        if samples.count > 30 * 16_000, engine is any BatchASREngineAdapting {
            return try await withPreparedModel { generation in
                let transcript = try await FileTranscriber(transcriber: self)
                    .transcribe(chunks: FileAudioChunks(samples: samples), generation: generation)
                return Self.result(transcript, since: arrived)
            }
        }

        // Claim residency before waiting on the shared warm-up. Otherwise the
        // warm-up owner can drop its busy count just before this continuation
        // resumes, leaving a narrow window where polite unload sees an idle
        // engine even though a real dictation is queued for it.
        activeOperations += 1
        defer { activeOperations -= 1 }
        let expectedGeneration = generation
        try Task.checkCancellation()
        if let inferenceWarmupTask {
            try await inferenceWarmupTask.value
            // Waiting on an unstructured task does not consume the waiter's
            // cancellation. Escape/deadline may have abandoned this dictation
            // while the shared warm-up was finishing; never start inference for it.
            try Task.checkCancellation()
        }
        guard generation == expectedGeneration, loadedDirectory != nil else {
            throw CancellationError()
        }
        let queued = arrived.duration(to: .now)
        let result = try await engine.transcribe(samples: samples)
        try Task.checkCancellation()
        guard generation == expectedGeneration, loadedDirectory != nil else {
            throw CancellationError()
        }
        return ASRResult(
            text: result.text,
            words: result.words,
            audioDuration: result.audioDuration,
            processingDuration: result.processingDuration,
            engineDispatchDuration: result.engineDispatchDuration,
            queueingDuration: Double(queued.components.seconds)
                + Double(queued.components.attoseconds) / 1e18,
            phaseTimings: result.phaseTimings
        )
    }

    /// Execute representative inference after all optional models have loaded.
    /// Loading Core ML weights alone does not compile/materialize every
    /// prediction path; without this, the first short dictation (or the first
    /// one containing a custom-term candidate) can be seconds slower than the
    /// steady state.
    public func warmUpInference() async throws {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }
        let expectedGeneration = generation
        if let inferenceWarmupTask {
            try await inferenceWarmupTask.value
            guard generation == expectedGeneration, loadedDirectory != nil else {
                throw CancellationError()
            }
            return
        }

        inferenceWarmupEpoch &+= 1
        let warmupEpoch = inferenceWarmupEpoch
        let engine = engine
        let task = Task {
            _ = try await engine.transcribe(samples: [Float](repeating: 0, count: 16_000))
        }
        inferenceWarmupTask = task
        activeOperations += 1
        defer {
            activeOperations -= 1
            if inferenceWarmupEpoch == warmupEpoch {
                inferenceWarmupTask = nil
            }
        }
        try await task.value
        guard generation == expectedGeneration, loadedDirectory != nil else {
            throw CancellationError()
        }
    }

    /// Free up memory under the model — forced.
    ///
    /// Used by wedge recovery and model deletion: it must work even when a
    /// zombie inference will never return. A load in flight is fenced out by
    /// the generation bump; its caller sees cancellation.
    public func unload() async {
        generation += 1
        inferenceWarmupEpoch &+= 1
        inferenceWarmupTask?.cancel()
        inferenceWarmupTask = nil
        await engine.unload()
        loadedDirectory = nil
    }

    /// Free up memory under the model — polite, for residency management.
    ///
    /// Refuses while a load or recognition is in flight: interleaving an
    /// unload with live work on the reentrant engine actor would end in a
    /// nondeterministic state. The owner re-evaluates on completion events.
    @discardableResult
    public func unloadIfIdle() async -> Bool {
        guard !isBusy else { return false }
        await unload()
        return true
    }
}
