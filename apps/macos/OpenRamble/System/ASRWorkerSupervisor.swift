import ASRWorkerProtocol
import Darwin
import DictationCore
import Foundation
import LocalASR
import os

/// Recognition lifecycle used by AppState. Production crosses a process
/// boundary; tests may continue to use LocalTranscriber through the same API.
public protocol DictationRecognizing: Sendable {
    /// Whether an inference timeout already kills/fences the exact generation
    /// and schedules its own full rewarm.
    var ownsTimeoutRecovery: Bool { get }
    var isPrepared: Bool { get async }
    var isBusy: Bool { get async }
    /// Causal changes to full inference readiness. A process-backed recognizer
    /// must publish `false` as soon as its ready generation dies and `true`
    /// only after the replacement has completed a real warm inference.
    func readinessChanges() async -> AsyncStream<Bool>
    func prepare(modelDirectory: URL) async throws
    func prepareVocabulary(modelDirectory: URL, boost: VocabularyBoost) async throws
    func transcribe(fileURL: URL, languageHint: String?) async throws -> ASRResult
    func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult
    func warmUpInference() async throws
    func unload() async
    func unloadIfIdle() async -> Bool
}

extension DictationRecognizing {
    public var ownsTimeoutRecovery: Bool { false }

    public func readinessChanges() async -> AsyncStream<Bool> {
        AsyncStream { $0.finish() }
    }
}

extension LocalTranscriber: DictationRecognizing {}

enum ASRWorkerTransportError: Error, Equatable, Sendable {
    case executableMissing
    case launchFailed(String)
    case disconnected
    case protocolViolation
    case requestTimedOut
    case generationInvalidated
}

/// A queued reader or writer owns a duplicate, never the descriptor number
/// stored by the current generation. Closing an old generation can therefore
/// never retarget delayed I/O at a new pipe that reused the same integer.
enum ASRWorkerDescriptor {
    static func configureOwned(_ descriptor: Int32, suppressSIGPIPE: Bool = false) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw ASRWireError.systemCall(operation: "fcntl(F_SETFD)", code: errno)
        }
        if suppressSIGPIPE {
            try ASRWireIO.disableSIGPIPE(on: descriptor)
        }
    }

    static func duplicate(_ descriptor: Int32, suppressSIGPIPE: Bool = false) throws -> Int32 {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw ASRWireError.systemCall(operation: "dup", code: errno)
        }
        do {
            try configureOwned(duplicate, suppressSIGPIPE: suppressSIGPIPE)
        } catch {
            Darwin.close(duplicate)
            throw error
        }
        return duplicate
    }
}

struct ASRWorkerDeadlines: Sendable {
    // Launching a process and reading its first frame is not model work, but
    // it is not instant either: right after an install the Mac is still
    // flushing the 586 MB it just wrote, and two seconds was tight enough that
    // a first run could time out here and burn its attempts on a busy disk.
    var hello: Duration = .seconds(10)
    // Main TDT and the optional CTC vocabulary graph are both materialized
    // before Ready, and a first-ever Core ML/ANE specialization owns most of
    // that time — heavy CPU work of machine-dependent length. Preparation
    // phases are therefore watched for STALL (no CPU burn; see
    // PreparationStallPolicy), which catches a call wedged on a dead system
    // service in ~30 s regardless of these values. The durations below are
    // only the far ceiling for the pathological spin that burns CPU without
    // finishing; a healthy slow Mac never meets either bound.
    var preparation: Duration = .seconds(600)
    var vocabulary: Duration = .seconds(600)
    var warmup: Duration = .seconds(600)
    // Dropping loaded models is bookkeeping plus deallocations, never a model
    // load; a worker that cannot answer in five seconds has earned the kill
    // fallback.
    var unload: Duration = .seconds(5)
    var fileTranscription: Duration = .seconds(60)
    var transcription: @Sendable (TimeInterval) -> Duration = { audioDuration in
        // A far ceiling, not a budget: the stall watchdog decides whether this
        // recognition is wedged by watching the worker's CPU, and this bound
        // only catches a pathological spin that burns CPU forever without
        // finishing. It still wins the race against DictationController's own
        // backstop by a deterministic margin, so the worker gets to kill,
        // fence, and schedule recovery before the outer task is cancelled.
        TranscriptionDeadline.deadline(forAudioDuration: audioDuration)
            - .milliseconds(500)
    }
}

struct KilledASRWorker: @unchecked Sendable {
    let process: Process
    let generation: UInt64
    let processIdentifier: Int32
}

/// Synchronously reachable from cancellation handlers. The actor may be
/// suspended waiting for a reply; this holder is what makes exact-PID kill
/// independent of actor progress.
final class ASRWorkerProcessHolder: @unchecked Sendable {
    struct Snapshot: @unchecked Sendable {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let generation: UInt64
    }

    private let lock = NSLock()
    private var current: Snapshot?

    func install(_ snapshot: Snapshot) {
        lock.withLock { current = snapshot }
    }

    func snapshot() -> Snapshot? {
        lock.withLock { current }
    }

    @discardableResult
    func kill(generation expectedGeneration: UInt64? = nil) -> KilledASRWorker? {
        let snapshot: Snapshot? = lock.withLock {
            guard let current else { return nil }
            if let expectedGeneration, current.generation != expectedGeneration { return nil }
            self.current = nil
            return current
        }
        guard let snapshot else { return nil }

        let processIdentifier = snapshot.process.processIdentifier
        if snapshot.process.isRunning {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        try? snapshot.input.close()
        try? snapshot.output.close()
        return KilledASRWorker(
            process: snapshot.process,
            generation: snapshot.generation,
            processIdentifier: processIdentifier
        )
    }
}

/// Owns one persistent, private ASR child. A timed-out Core ML call is not
/// cancelled in place: its entire process generation is killed and reaped,
/// the current take fails within its budget, and a fully configured generation
/// is rebuilt outside that stop-to-text critical path.
public actor ASRWorkerSupervisor: DictationRecognizing {
    public nonisolated var ownsTimeoutRecovery: Bool { true }
    private struct PendingRequest {
        let requestID: UInt64
        let generation: UInt64
        let continuation: CheckedContinuation<ASRWireFrame, Error>
        let watchdog: Task<Void, Never>
    }

    struct OperationWaiter {
        let identifier: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let executableURL: URL
    private let executableArguments: [String]
    private let deadlines: ASRWorkerDeadlines
    private let processHolder = ASRWorkerProcessHolder()
    private let writerQueue = DispatchQueue(
        label: "is.waiwai.dictation.asr-worker-writer",
        qos: .userInitiated
    )
    private let log = Logger(subsystem: "is.waiwai.dictation", category: "asr-supervisor")

    private var generation: UInt64 = 0
    private var nextRequestID: UInt64 = 0
    private var pendingRequest: PendingRequest?
    private var processesToReap: [KilledASRWorker] = []

    private var loadedMainGeneration: UInt64?
    private var loadedVocabularyGeneration: UInt64?
    private var warmedGeneration: UInt64?
    private var readyGeneration: UInt64?
    private var cachedModelDirectory: URL?
    private var cachedVocabulary: ASRWorkerVocabulary?
    private var hasCompleteConfiguration = false
    private var vocabularyRevision: UInt64 = 0

    private var operationHeld = false
    private var nextOperationWaiterID: UInt64 = 0
    private var operationWaiters: [OperationWaiter] = []
    /// Explicit unload is a non-cancellable ownership boundary. It runs before
    /// ordinary queued work once the active operation yields, so model deletion
    /// cannot be overtaken by another warm/prepare call.
    private var unloadOperationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Public calls capture this before waiting for the operation gate. Unload
    /// advances it while holding that gate; calls admitted against the old model
    /// configuration then fail without launching a replacement child.
    private var configurationEpoch: UInt64 = 0
    private var recoverySequence: UInt64 = 0
    private var recoveryTask: Task<Void, Never>?
    private var readinessObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    /// Stall detection for preparation phases; injectable so tests exercise
    /// both verdicts without production-scale windows.
    private let stallPolicy: PreparationStallPolicy
    /// Reads the worker's cumulative CPU time; injectable for determinism.
    private let workerCPUTime: @Sendable (Int32) -> Duration?
    /// Reports the current memory-pressure tier; the default keeps every
    /// existing construction (and test) on the old always-respawn behavior.
    private let pressureTier: @Sendable () -> MemoryPressureTier
    /// The backoff decision is injectable so tests exercise the loop without
    /// production-scale waits; the policy's values are table-tested.
    private let recoveryBackoffDecision:
        @Sendable (MemoryPressureTier) -> WorkerRecoveryBackoffPolicy.Decision

    init(
        executableURL: URL,
        executableArguments: [String] = [],
        deadlines: ASRWorkerDeadlines = ASRWorkerDeadlines(),
        stallPolicy: PreparationStallPolicy = PreparationStallPolicy(),
        workerCPUTime: @escaping @Sendable (Int32) -> Duration? =
            ASRWorkerSupervisor.processCPUTime,
        pressureTier: @escaping @Sendable () -> MemoryPressureTier = { .normal },
        recoveryBackoffDecision: @escaping @Sendable (MemoryPressureTier)
            -> WorkerRecoveryBackoffPolicy.Decision = { tier in
                WorkerRecoveryBackoffPolicy.decision(
                    tier: tier,
                    jitterUnit: Double.random(in: 0..<1)
                )
            }
    ) {
        self.executableURL = executableURL
        self.executableArguments = executableArguments
        self.deadlines = deadlines
        self.stallPolicy = stallPolicy
        self.workerCPUTime = workerCPUTime
        self.pressureTier = pressureTier
        self.recoveryBackoffDecision = recoveryBackoffDecision
    }

    public var isPrepared: Bool {
        guard let snapshot = processHolder.snapshot() else { return false }
        return snapshot.process.isRunning && readyGeneration == snapshot.generation
    }

    public var isBusy: Bool { operationHeld }

    public func readinessChanges() -> AsyncStream<Bool> {
        let identifier = UUID()
        return AsyncStream { continuation in
            readinessObservers[identifier] = continuation
            continuation.yield(isPrepared)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeReadinessObserver(identifier) }
            }
        }
    }

    public func prepare(modelDirectory: URL) async throws {
        let admittedEpoch = configurationEpoch
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard admittedEpoch == configurationEpoch else {
            throw ASRWorkerTransportError.generationInvalidated
        }
        cachedModelDirectory = modelDirectory

        try await retryTransportOnce {
            let activeGeneration = try await self.ensureLaunched()
            if self.hasCompleteConfiguration, self.readyGeneration != activeGeneration {
                try await self.prepareCompleteGeneration(activeGeneration)
            } else if self.loadedMainGeneration != activeGeneration {
                try await self.prepareMain(modelDirectory, generation: activeGeneration)
            }
        }
    }

    public func prepareVocabulary(modelDirectory: URL, boost: VocabularyBoost) async throws {
        let admittedEpoch = configurationEpoch
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard admittedEpoch == configurationEpoch else {
            throw ASRWorkerTransportError.generationInvalidated
        }
        guard cachedModelDirectory != nil else { throw ASREngineError.modelsNotLoaded }

        vocabularyRevision &+= 1
        let proposed = ASRWorkerVocabulary(
            modelDirectory: modelDirectory.path,
            revision: vocabularyRevision,
            terms: boost.terms.map {
                ASRWorkerVocabulary.Term(text: $0.text, aliases: $0.aliases)
            },
            minimumSimilarity: boost.minSimilarity,
            biasWeight: boost.biasWeight
        )

        do {
            try await retryTransportOnce {
                let activeGeneration = try await self.ensureLaunched()
                if self.loadedMainGeneration != activeGeneration {
                    guard let cachedModelDirectory = self.cachedModelDirectory else {
                        throw ASREngineError.modelsNotLoaded
                    }
                    try await self.prepareMain(
                        cachedModelDirectory,
                        generation: activeGeneration
                    )
                }
                try await self.prepareVocabulary(proposed, generation: activeGeneration)
            }
            cachedVocabulary = proposed
        } catch let failure as ASRWorkerFailure where failure.code == .vocabularyInvalid {
            throw VocabularyBoostError.termNotTokenizable(index: failure.termIndex ?? 1)
        }
    }

    public func warmUpInference() async throws {
        let admittedEpoch = configurationEpoch
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard admittedEpoch == configurationEpoch else {
            throw ASRWorkerTransportError.generationInvalidated
        }
        guard cachedModelDirectory != nil else { throw ASREngineError.modelsNotLoaded }
        try await retryTransportOnce {
            let activeGeneration = try await self.ensureLaunched()
            if self.loadedMainGeneration != activeGeneration {
                guard let cachedModelDirectory = self.cachedModelDirectory else {
                    throw ASREngineError.modelsNotLoaded
                }
                try await self.prepareMain(cachedModelDirectory, generation: activeGeneration)
            }
            if let cachedVocabulary,
               self.loadedVocabularyGeneration != activeGeneration {
                try await self.prepareVocabulary(cachedVocabulary, generation: activeGeneration)
            }
            try await self.warm(generation: activeGeneration)
            self.hasCompleteConfiguration = true
        }
    }

    public func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult {
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("empty recording")
        }
        guard samples.count <= ASRWorkerProtocol.maximumSamples else {
            throw ASREngineError.unsupportedAudioFormat("recording exceeds the in-memory worker limit")
        }

        let admittedEpoch = configurationEpoch
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard admittedEpoch == configurationEpoch else {
            throw ASRWorkerTransportError.generationInvalidated
        }
        let duration = Double(samples.count) / Double(ASRWorkerProtocol.sampleRate)
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let request = ASRWorkerTranscribeSamples(
            sampleRate: ASRWorkerProtocol.sampleRate,
            sampleCount: samples.count,
            languageHint: languageHint
        )

        return try await transcribeOnce(
            metadata: ASRWorkerJSON.encode(request),
            payload: payload,
            kind: .transcribeSamples,
            deadline: deadlines.transcription(duration)
        )
    }

    public func transcribe(fileURL: URL, languageHint: String?) async throws -> ASRResult {
        let admittedEpoch = configurationEpoch
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard admittedEpoch == configurationEpoch else {
            throw ASRWorkerTransportError.generationInvalidated
        }
        let request = ASRWorkerTranscribeFile(path: fileURL.path, languageHint: languageHint)
        return try await transcribeOnce(
            metadata: ASRWorkerJSON.encode(request),
            payload: Data(),
            kind: .transcribeFile,
            deadline: deadlines.fileTranscription
        )
    }

    public func unload() async {
        cancelRecovery()
        await acquireUnloadOperation()
        defer { releaseOperation() }
        cancelRecovery()
        configurationEpoch &+= 1
        invalidateCurrentGeneration(error: ASRWorkerTransportError.generationInvalidated)
        cachedModelDirectory = nil
        cachedVocabulary = nil
        hasCompleteConfiguration = false
        await reapKilledProcesses()
    }

    public func unloadIfIdle() async -> Bool {
        guard !operationHeld else { return false }
        // Keep the idle check and the state transition in one actor turn;
        // hopping through `unload()` here would leave a reentrancy window. Hold
        // the same operation gate through the whole transition so a queued
        // dictation cannot interleave with it.
        operationHeld = true
        defer { releaseOperation() }
        cancelRecovery()
        // Prefer dropping the models inside a living worker: spawn, dyld and
        // framework init stay paid for, and the next prepare reuses the
        // process. Any hiccup falls back to the old exact-PID kill.
        if let snapshot = processHolder.snapshot(),
           snapshot.process.isRunning,
           loadedMainGeneration == snapshot.generation {
            do {
                let frame = try await request(
                    kind: .unloadModels,
                    metadata: Data(),
                    generation: snapshot.generation,
                    deadline: deadlines.unload
                )
                _ = try requireAcknowledgement(frame)
                clearLoadedState(for: snapshot.generation)
                log.notice(
                    "worker models unloaded, process resident generation=\(snapshot.generation)"
                )
                return true
            } catch {
                log.error("in-place model unload failed; falling back to worker kill")
            }
        }
        invalidateCurrentGeneration(error: ASRWorkerTransportError.generationInvalidated)
        await reapKilledProcesses()
        return true
    }

    deinit {
        // Closing the inherited pipes is not enough when Core ML is stuck.
        // Process death is the ownership boundary, so teardown uses the same
        // exact-PID path as deadlines and cancellation.
        recoveryTask?.cancel()
        for observer in readinessObservers.values { observer.finish() }
        if let killed = processHolder.kill() {
            Thread.detachNewThread {
                killed.process.waitUntilExit()
            }
        }
    }

    private func transcribeOnce(
        metadata: Data,
        payload: Data,
        kind: ASRWireKind,
        deadline: Duration
    ) async throws -> ASRResult {
        try Task.checkCancellation()
        do {
            let activeGeneration = try await ensureReadyGeneration()
            let frame = try await request(
                kind: kind,
                metadata: metadata,
                payload: payload,
                generation: activeGeneration,
                deadline: deadline
            )
            return try decodeResult(frame)
        } catch {
            try Task.checkCancellation()
            if shouldRecycle(after: error) {
                // Never reload and re-run inference inside the user's bounded
                // stop-to-text budget. Fail immediately with the audio
                // preserved by DictationController; restore readiness in the
                // background for the next take.
                invalidateCurrentGeneration(error: ASRWorkerTransportError.generationInvalidated)
                scheduleRecovery()
            }
            if error as? ASRWorkerTransportError == .requestTimedOut {
                throw TranscriptionTimeout(deadline: deadline)
            }
            throw map(error)
        }
    }

    private func ensureReadyGeneration() async throws -> UInt64 {
        if let snapshot = processHolder.snapshot(),
           snapshot.process.isRunning,
           readyGeneration == snapshot.generation {
            return snapshot.generation
        }
        return try await launchAndPrepareCompleteGeneration()
    }

    private func launchAndPrepareCompleteGeneration() async throws -> UInt64 {
        let activeGeneration = try await ensureLaunched()
        try await prepareCompleteGeneration(activeGeneration)
        return activeGeneration
    }

    private func prepareCompleteGeneration(_ activeGeneration: UInt64) async throws {
        guard let modelDirectory = cachedModelDirectory else {
            throw ASREngineError.modelsNotLoaded
        }
        if loadedMainGeneration != activeGeneration {
            try await prepareMain(modelDirectory, generation: activeGeneration)
        }
        if let cachedVocabulary, loadedVocabularyGeneration != activeGeneration {
            try await prepareVocabulary(cachedVocabulary, generation: activeGeneration)
        }
        if warmedGeneration != activeGeneration {
            try await warm(generation: activeGeneration)
        }
        markReady(activeGeneration)
    }

    private func prepareMain(_ directory: URL, generation: UInt64) async throws {
        let metadata = try ASRWorkerJSON.encode(
            ASRWorkerPrepareMain(modelDirectory: directory.path)
        )
        let frame = try await request(
            kind: .prepareMain,
            metadata: metadata,
            generation: generation,
            deadline: deadlines.preparation
        )
        _ = try requireAcknowledgement(frame)
        loadedMainGeneration = generation
        readyGeneration = nil
    }

    private func prepareVocabulary(
        _ vocabulary: ASRWorkerVocabulary,
        generation: UInt64
    ) async throws {
        let frame = try await request(
            kind: .prepareVocabulary,
            metadata: ASRWorkerJSON.encode(vocabulary),
            generation: generation,
            deadline: deadlines.vocabulary
        )
        let acknowledgement = try requireAcknowledgement(frame)
        guard acknowledgement.vocabularyRevision == vocabulary.revision else {
            throw ASRWorkerTransportError.protocolViolation
        }
        loadedVocabularyGeneration = generation
    }

    private func warm(generation: UInt64) async throws {
        let frame = try await request(
            kind: .warmInference,
            metadata: Data("{}".utf8),
            generation: generation,
            deadline: deadlines.warmup
        )
        _ = try requireAcknowledgement(frame)
        guard let snapshot = processHolder.snapshot(),
              snapshot.generation == generation,
              snapshot.process.isRunning
        else {
            throw ASRWorkerTransportError.disconnected
        }
        warmedGeneration = generation
        markReady(generation)
    }

    private func ensureLaunched() async throws -> UInt64 {
        if let snapshot = processHolder.snapshot(), snapshot.process.isRunning {
            return snapshot.generation
        }
        await reapKilledProcesses()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ASRWorkerTransportError.executableMissing
        }

        generation &+= 1
        let launchedGeneration = generation
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let input = inputPipe.fileHandleForWriting
        let output = outputPipe.fileHandleForReading
        try ASRWorkerDescriptor.configureOwned(
            input.fileDescriptor,
            suppressSIGPIPE: true
        )
        try ASRWorkerDescriptor.configureOwned(output.fileDescriptor)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = executableArguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        process.terminationHandler = { [weak self] finished in
            Task {
                await self?.processExited(
                    generation: launchedGeneration,
                    processIdentifier: finished.processIdentifier,
                    status: finished.terminationStatus
                )
            }
        }
        do {
            try process.run()
        } catch {
            try? input.close()
            try? output.close()
            throw ASRWorkerTransportError.launchFailed(error.localizedDescription)
        }
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()

        processHolder.install(
            .init(
                process: process,
                input: input,
                output: output,
                generation: launchedGeneration
            )
        )
        do {
            try startReader(output: output, generation: launchedGeneration)
        } catch {
            if let killed = processHolder.kill(generation: launchedGeneration) {
                processesToReap.append(killed)
            }
            await reapKilledProcesses()
            throw ASRWorkerTransportError.launchFailed("protocol reader could not start")
        }
        log.info(
            "worker launched generation=\(launchedGeneration) pid=\(process.processIdentifier)"
        )

        do {
            let hello = ASRWorkerHello(
                protocolVersion: ASRWorkerProtocol.version,
                parentProcessIdentifier: getpid(),
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
            )
            let response = try await request(
                kind: .hello,
                metadata: ASRWorkerJSON.encode(hello),
                generation: launchedGeneration,
                deadline: deadlines.hello
            )
            guard response.kind == .helloAcknowledged else {
                throw ASRWorkerTransportError.protocolViolation
            }
            let acknowledgement = try ASRWorkerJSON.decode(
                ASRWorkerHelloAcknowledgement.self,
                from: response.metadata
            )
            guard acknowledgement.protocolVersion == ASRWorkerProtocol.version,
                  acknowledgement.workerProcessIdentifier == process.processIdentifier
            else {
                throw ASRWorkerTransportError.protocolViolation
            }
        } catch {
            invalidateCurrentGeneration(error: ASRWorkerTransportError.generationInvalidated)
            await reapKilledProcesses()
            throw error
        }
        return launchedGeneration
    }

    private func request(
        kind: ASRWireKind,
        metadata: Data,
        payload: Data = Data(),
        generation: UInt64,
        deadline: Duration
    ) async throws -> ASRWireFrame {
        try Task.checkCancellation()
        guard metadata.count <= ASRWorkerProtocol.maximumMetadataBytes,
              payload.count <= ASRWorkerProtocol.maximumPCMBytes
        else {
            throw ASRWorkerTransportError.protocolViolation
        }
        guard pendingRequest == nil,
              let snapshot = processHolder.snapshot(),
              snapshot.generation == generation,
              snapshot.process.isRunning
        else {
            throw ASRWorkerTransportError.disconnected
        }

        nextRequestID &+= 1
        let requestID = nextRequestID
        let frame = ASRWireFrame(
            kind: kind,
            requestID: requestID,
            metadata: metadata,
            payload: payload
        )
        let holder = processHolder
        let writerDescriptor: Int32
        do {
            writerDescriptor = try ASRWorkerDescriptor.duplicate(
                snapshot.input.fileDescriptor,
                suppressSIGPIPE: true
            )
        } catch {
            throw ASRWorkerTransportError.disconnected
        }

        let workerProcessIdentifier = snapshot.process.processIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ASRWireFrame, Error>) in
                let watchdog = Self.usesStallWatchdog(kind)
                    ? makeStallWatchdog(
                        requestID: requestID,
                        generation: generation,
                        processIdentifier: workerProcessIdentifier,
                        ceiling: deadline
                    )
                    : Task { [weak self] in
                        do {
                            try await Task.sleep(for: deadline)
                        } catch {
                            return
                        }
                        await self?.requestTimedOut(requestID: requestID, generation: generation)
                    }
                pendingRequest = PendingRequest(
                    requestID: requestID,
                    generation: generation,
                    continuation: continuation,
                    watchdog: watchdog
                )
                writerQueue.async { [weak self] in
                    defer { Darwin.close(writerDescriptor) }
                    do {
                        try ASRWireIO.write(frame, to: writerDescriptor)
                    } catch {
                        Task {
                            await self?.requestWriteFailed(
                                requestID: requestID,
                                generation: generation
                            )
                        }
                    }
                }
            }
        } onCancel: {
            let killed = holder.kill(generation: generation)
            Task { [weak self] in
                await self?.requestCancelled(
                    requestID: requestID,
                    generation: generation,
                    killed: killed
                )
            }
        }
    }

    private func startReader(output: FileHandle, generation: UInt64) throws {
        let descriptor = try ASRWorkerDescriptor.duplicate(output.fileDescriptor)
        Thread.detachNewThread { [weak self] in
            defer { Darwin.close(descriptor) }
            // @Sendable is load-bearing on these hops: the app target's default
            // MainActor isolation would otherwise be inferred onto the closures,
            // and Swift 6.2.3 rejects sending them from the reader thread.
            do {
                while let frame = try ASRWireIO.read(from: descriptor) {
                    Task { @Sendable [weak self] in
                        await self?.received(frame, generation: generation)
                    }
                }
                Task { @Sendable [weak self] in
                    await self?.connectionEnded(generation: generation)
                }
            } catch {
                Task { @Sendable [weak self] in
                    await self?.connectionEnded(generation: generation)
                }
            }
        }
    }

    private func received(_ frame: ASRWireFrame, generation: UInt64) {
        guard let pendingRequest,
              pendingRequest.generation == generation,
              pendingRequest.requestID == frame.requestID
        else {
            log.info("discarded stale worker response generation=\(generation)")
            return
        }
        pendingRequest.watchdog.cancel()
        self.pendingRequest = nil
        if frame.kind == .failure {
            do {
                let failure = try ASRWorkerJSON.decode(ASRWorkerFailure.self, from: frame.metadata)
                pendingRequest.continuation.resume(throwing: failure)
            } catch {
                pendingRequest.continuation.resume(
                    throwing: ASRWorkerTransportError.protocolViolation
                )
            }
        } else {
            pendingRequest.continuation.resume(returning: frame)
        }
    }

    /// Which phases are judged by whether the worker is doing work rather
    /// than by how long it has taken.
    ///
    /// Preparation was given this treatment because a first specialization is
    /// heavy work of machine-dependent length. Recognition needs it for the
    /// same reason and with more at stake: it was killed on a fixed clock —
    /// 2.5 s for a fifteen-second take — so a slow-but-healthy run cost the
    /// person their words *and* the loaded model, which made the next take
    /// cold and even more likely to miss the same bound. Judge the work, not
    /// the clock, everywhere the clock cannot tell slow from broken.
    static func usesStallWatchdog(_ kind: ASRWireKind) -> Bool {
        switch kind {
        case .prepareMain, .prepareVocabulary, .warmInference,
             .transcribeSamples, .transcribeFile:
            return true
        default:
            return false
        }
    }

    /// A stall-aware watchdog for preparation phases: kills on a windless
    /// stretch of worker CPU, not on honest slowness. The ceiling only bounds
    /// a pathological spin.
    private func makeStallWatchdog(
        requestID: UInt64,
        generation: UInt64,
        processIdentifier: Int32,
        ceiling: Duration
    ) -> Task<Void, Never> {
        Task { [weak self, stallPolicy, workerCPUTime] in
            let cadence = stallPolicy.effectiveSampleInterval(ceiling: ceiling)
            var lastCPU = workerCPUTime(processIdentifier) ?? .zero
            var sinceProgress: Duration = .zero
            var total: Duration = .zero
            while total < ceiling {
                do {
                    try await Task.sleep(for: cadence)
                } catch {
                    return
                }
                total += cadence
                if let cpu = workerCPUTime(processIdentifier), cpu > lastCPU {
                    if cpu - lastCPU >= stallPolicy.minimumProgress {
                        sinceProgress = .zero
                    } else {
                        sinceProgress += cadence
                    }
                    lastCPU = cpu
                } else {
                    // A vanished reading counts as no progress; a dead process
                    // is reported by its own exit path first.
                    sinceProgress += cadence
                }
                if stallPolicy.verdict(elapsedSinceProgress: sinceProgress) == .wedged {
                    break
                }
            }
            await self?.requestTimedOut(requestID: requestID, generation: generation)
        }
    }

    /// One timebase read for the process lifetime; numer/denom never change.
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Cumulative user+system CPU time of the exact worker process.
    static func processCPUTime(_ processIdentifier: Int32) -> Duration? {
        var info = rusage_info_current()
        let succeeded = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_CURRENT, rebound) == 0
            }
        }
        guard succeeded else { return nil }
        // ri_*_time are Mach time units, not nanoseconds: on Apple Silicon a
        // tick is 125/3 ns, and reading ticks as nanoseconds shrank real burn
        // ~41× below the progress threshold — a live specialization looked
        // windless. Convert exactly, split to dodge overflow.
        let timebase = Self.machTimebase
        guard timebase.denom != 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        let nanos = (ticks / denom) * numer + ((ticks % denom) * numer) / denom
        return .nanoseconds(Int64(clamping: nanos))
    }

    private func requestTimedOut(requestID: UInt64, generation: UInt64) {
        guard let pendingRequest,
              pendingRequest.requestID == requestID,
              pendingRequest.generation == generation
        else { return }
        self.pendingRequest = nil
        if let killed = processHolder.kill(generation: generation) {
            processesToReap.append(killed)
            log.error(
                "worker timeout killed generation=\(generation) pid=\(killed.processIdentifier)"
            )
        }
        clearLoadedState(for: generation)
        pendingRequest.continuation.resume(throwing: ASRWorkerTransportError.requestTimedOut)
    }

    private func requestWriteFailed(requestID: UInt64, generation: UInt64) {
        guard let pendingRequest,
              pendingRequest.requestID == requestID,
              pendingRequest.generation == generation
        else { return }
        pendingRequest.watchdog.cancel()
        self.pendingRequest = nil
        if let killed = processHolder.kill(generation: generation) {
            processesToReap.append(killed)
        }
        clearLoadedState(for: generation)
        pendingRequest.continuation.resume(throwing: ASRWorkerTransportError.disconnected)
    }

    private func requestCancelled(
        requestID: UInt64,
        generation: UInt64,
        killed: KilledASRWorker?
    ) {
        if let killed { processesToReap.append(killed) }
        clearLoadedState(for: generation)
        guard let pendingRequest,
              pendingRequest.requestID == requestID,
              pendingRequest.generation == generation
        else { return }
        pendingRequest.watchdog.cancel()
        self.pendingRequest = nil
        pendingRequest.continuation.resume(throwing: CancellationError())
    }

    private func connectionEnded(generation: UInt64) {
        // EOF is not proof that the process exited; a corrupted worker could
        // close stdout and remain alive with the model resident. Reclaim the
        // exact owned PID and reap it before any retry launches a successor.
        let wasReady = readyGeneration == generation
        let killed = processHolder.kill(generation: generation)
        if let killed {
            processesToReap.append(killed)
        }
        clearLoadedState(for: generation)
        if let pendingRequest, pendingRequest.generation == generation {
            pendingRequest.watchdog.cancel()
            self.pendingRequest = nil
            pendingRequest.continuation.resume(throwing: ASRWorkerTransportError.disconnected)
            return
        }
        // Only the first EOF/termination callback owns recovery. A duplicate
        // callback sees neither the holder nor Ready and cannot spawn another
        // generation. Explicit unload clears Ready before its child exits, so
        // it also cannot accidentally rewarm an intentionally evicted model.
        if killed != nil, wasReady { scheduleRecovery() }
    }

    private func processExited(generation: UInt64, processIdentifier: Int32, status: Int32) {
        connectionEnded(generation: generation)
        log.info(
            "worker exited generation=\(generation) pid=\(processIdentifier) status=\(status)"
        )
    }

    private func invalidateCurrentGeneration(error: any Error) {
        let activeGeneration = processHolder.snapshot()?.generation
        if let killed = processHolder.kill(generation: activeGeneration) {
            processesToReap.append(killed)
            log.notice(
                "worker invalidated generation=\(killed.generation) pid=\(killed.processIdentifier)"
            )
        }
        if let activeGeneration { clearLoadedState(for: activeGeneration) }
        if let pendingRequest {
            pendingRequest.watchdog.cancel()
            self.pendingRequest = nil
            pendingRequest.continuation.resume(throwing: error)
        }
    }

    private func clearLoadedState(for generation: UInt64) {
        if loadedMainGeneration == generation { loadedMainGeneration = nil }
        if loadedVocabularyGeneration == generation { loadedVocabularyGeneration = nil }
        if warmedGeneration == generation { warmedGeneration = nil }
        if readyGeneration == generation {
            readyGeneration = nil
            publishReadiness(false)
        }
    }

    private func markReady(_ generation: UInt64) {
        let changed = readyGeneration != generation
        readyGeneration = generation
        if changed { publishReadiness(true) }
    }

    private func publishReadiness(_ isReady: Bool) {
        for observer in readinessObservers.values { observer.yield(isReady) }
    }

    private func removeReadinessObserver(_ identifier: UUID) {
        readinessObservers.removeValue(forKey: identifier)
    }

    private func reapKilledProcesses() async {
        let killed = processesToReap
        processesToReap.removeAll()
        for worker in killed {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    worker.process.waitUntilExit()
                    continuation.resume()
                }
            }
        }
    }

    private func retryTransportOnce(
        _ operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            try Task.checkCancellation()
            guard shouldRetryPreparation(after: error) else {
                if shouldRecycle(after: error) {
                    invalidateCurrentGeneration(
                        error: ASRWorkerTransportError.generationInvalidated
                    )
                    await reapKilledProcesses()
                }
                throw map(error)
            }

            invalidateCurrentGeneration(error: ASRWorkerTransportError.generationInvalidated)
            await reapKilledProcesses()
            do {
                try await operation()
            } catch {
                try Task.checkCancellation()
                if shouldRecycle(after: error) {
                    invalidateCurrentGeneration(
                        error: ASRWorkerTransportError.generationInvalidated
                    )
                    await reapKilledProcesses()
                }
                throw map(error)
            }
        }
    }

    private func requireAcknowledgement(_ frame: ASRWireFrame) throws -> ASRWorkerAcknowledgement {
        guard frame.kind == .acknowledged else {
            throw ASRWorkerTransportError.protocolViolation
        }
        return try ASRWorkerJSON.decode(ASRWorkerAcknowledgement.self, from: frame.metadata)
    }

    private func decodeResult(_ frame: ASRWireFrame) throws -> ASRResult {
        guard frame.kind == .result, frame.payload.isEmpty else {
            throw ASRWorkerTransportError.protocolViolation
        }
        let result = try ASRWorkerJSON.decode(ASRWorkerResult.self, from: frame.metadata)
        guard result.text.utf8.count <= ASRWorkerProtocol.maximumTranscriptUTF8Bytes,
              result.words.count <= ASRWorkerProtocol.maximumResultWords,
              result.audioDuration.isFinite,
              result.audioDuration >= 0,
              result.processingDuration.isFinite,
              result.processingDuration >= 0,
              result.words.allSatisfy({
                  $0.text.utf8.count <= ASRWorkerProtocol.maximumWordUTF8Bytes &&
                      $0.start.isFinite && $0.end.isFinite &&
                      $0.start >= 0 && $0.end >= $0.start &&
                      ($0.confidence.map {
                          $0.isFinite && $0 >= 0 && $0 <= 1
                      } ?? true)
              })
        else {
            throw ASRWorkerTransportError.protocolViolation
        }
        return ASRResult(
            text: result.text,
            words: result.words.map {
                ASRResult.Word(
                    text: $0.text,
                    start: $0.start,
                    end: $0.end,
                    confidence: $0.confidence
                )
            },
            audioDuration: result.audioDuration,
            processingDuration: result.processingDuration
        )
    }

    private func shouldRecycle(after error: any Error) -> Bool {
        if error is ASRWorkerTransportError { return true }
        guard let failure = error as? ASRWorkerFailure else { return false }
        return failure.code == .inferenceFailed || failure.code == .internalFailure
    }

    /// Loading may be retried once only when a launched worker disappears.
    /// Deadlines, malformed protocol, and launch/configuration failures are
    /// deterministic and must not silently consume a second full budget.
    private func shouldRetryPreparation(after error: any Error) -> Bool {
        error as? ASRWorkerTransportError == .disconnected
    }

    private func map(_ error: any Error) -> any Error {
        guard let failure = error as? ASRWorkerFailure else { return error }
        switch failure.code {
        case .modelsNotLoaded:
            return ASREngineError.modelsNotLoaded
        case .modelsUnavailable:
            return ASREngineError.modelsUnavailable(failure.message)
        case .invalidAudio:
            return ASREngineError.unsupportedAudioFormat(failure.message)
        case .cancelled:
            return ASREngineError.cancelled
        case .vocabularyInvalid:
            return VocabularyBoostError.termNotTokenizable(index: failure.termIndex ?? 1)
        case .protocolMismatch, .invalidRequest:
            return ASRWorkerTransportError.protocolViolation
        case .inferenceFailed, .internalFailure:
            return ASREngineError.inferenceFailed(failure.message)
        }
    }

    func acquireOperation() async throws {
        try Task.checkCancellation()
        if !operationHeld {
            operationHeld = true
            return
        }
        nextOperationWaiterID &+= 1
        let identifier = nextOperationWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    operationWaiters.append(
                        OperationWaiter(identifier: identifier, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelOperationWaiter(identifier: identifier)
            }
        }
        if Task.isCancelled {
            releaseOperation()
            throw CancellationError()
        }
    }

    func releaseOperation() {
        if !unloadOperationWaiters.isEmpty {
            unloadOperationWaiters.removeFirst().resume()
        } else if operationWaiters.isEmpty {
            operationHeld = false
        } else {
            operationWaiters.removeFirst().continuation.resume()
        }
    }

    var queuedOperationCount: Int { operationWaiters.count }
    var queuedUnloadOperationCount: Int { unloadOperationWaiters.count }

    private func acquireUnloadOperation() async {
        if !operationHeld {
            operationHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            unloadOperationWaiters.append(continuation)
        }
    }

    private func cancelOperationWaiter(identifier: UInt64) {
        guard let index = operationWaiters.firstIndex(where: {
            $0.identifier == identifier
        }) else { return }
        let waiter = operationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func scheduleRecovery() {
        guard hasCompleteConfiguration, cachedModelDirectory != nil else { return }
        recoverySequence &+= 1
        let sequence = recoverySequence
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            await self?.recoverInBackground(sequence: sequence)
        }
    }

    private func cancelRecovery() {
        recoverySequence &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func recoverInBackground(sequence: UInt64) async {
        do {
            // Never respawn a multi-gigabyte worker straight into the
            // starvation that just killed it. The wait happens before the
            // operation gate, so a real keypress-driven prepare is never
            // blocked behind the backoff.
            while case let .deferRespawn(recheckAfter) = recoveryBackoffDecision(
                pressureTier()
            ) {
                log.notice("worker respawn deferred under memory pressure")
                try await Task.sleep(for: recheckAfter)
                try Task.checkCancellation()
                guard recoverySequence == sequence else { return }
            }
            try await acquireOperation()
            defer { releaseOperation() }
            try Task.checkCancellation()
            guard recoverySequence == sequence else { return }
            if isPrepared { return }
            _ = try await launchAndPrepareCompleteGeneration()
            guard recoverySequence == sequence else { return }
            log.notice("worker readiness restored in background")
            recoveryTask = nil
        } catch is CancellationError {
            // Explicit unload or a newer recovery owns the next transition.
        } catch {
            guard recoverySequence == sequence else { return }
            recoveryTask = nil
            log.error("worker background recovery failed")
        }
    }
}

extension ASRWorkerTransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executableMissing:
            "The local recognition worker is missing from the application."
        case .launchFailed:
            "The local recognition worker could not start."
        case .disconnected, .generationInvalidated:
            "The local recognition worker stopped unexpectedly."
        case .protocolViolation:
            "The application and local recognition worker are incompatible."
        case .requestTimedOut:
            "Local recognition took too long and was restarted."
        }
    }
}
