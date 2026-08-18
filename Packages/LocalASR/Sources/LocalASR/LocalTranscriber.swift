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

    /// Recognize the recorded file.
    ///
    /// `languageHint` - BCP-47 code or `nil` for auto-detection; see
    /// `ASREngineAdapting.transcribe(samples:languageHint:)`.
    public func transcribe(fileURL: URL, languageHint: String? = nil) async throws -> ASRResult {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }

        let samples: [Float]
        do {
            samples = try reader.samples(from: fileURL)
        } catch let failure as AudioFileReader.Failure {
            throw ASREngineError.unsupportedAudioFormat(String(describing: failure))
        }

        try Task.checkCancellation()
        return try await transcribe(samples: samples, languageHint: languageHint)
    }

    /// Recognize a ready buffer.
    ///
    /// The entire recording goes into the engine, no matter how long it is: splicing
    /// He makes fifteen-second windows himself, with overlap and deduplication
    /// tokens. Previously, there was its own cutting of pauses - it was
    /// written against the silent loss of speech at the junction of the windows. The measurements showed that
    /// the reason for the loss was not in the length of the piece, but in the `melChunkContext` flag
    /// libraries; cutting cut phrases in the middle, slowed down parsing twice and
    /// on the main scenario (Russian speech with English inserts) lost three times
    /// more words than a properly configured engine. Details and numbers - in
    /// `docs/benchmarks.md`.
    public func transcribe(samples: [Float], languageHint: String? = nil) async throws -> ASRResult {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("empty recording")
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
        return try await engine.transcribe(samples: samples, languageHint: languageHint)
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
            _ = try await engine.transcribe(
                samples: [Float](repeating: 0, count: 16_000),
                languageHint: nil
            )
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
