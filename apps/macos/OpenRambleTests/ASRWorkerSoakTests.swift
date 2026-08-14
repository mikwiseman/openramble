import ASRWorkerProtocol
import Darwin
import DictationCore
import Foundation
import LocalASR
import Testing

private final class ASRWorkerSoakBundleMarker: NSObject {}

private let soakRuntimeDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/is.waiwai.dictation.tests/asr-worker-soak")
private let soakRequestURL = soakRuntimeDirectory.appendingPathComponent("request.json")
private let soakResultURL = soakRuntimeDirectory.appendingPathComponent("result.json")

@Suite("ASR worker deterministic soak", .serialized)
struct ASRWorkerSoakTests {
    @Test("1000-cycle soak and deterministic worker fault recovery")
    func longRunFaultAcceptance() async throws {
        let requestedCycles = runnerRequest()?.cycles
        let cycles = max(
            1_000,
            requestedCycles
                ?? Int(ProcessInfo.processInfo.environment["OPENRAMBLE_ASR_SOAK_CYCLES"] ?? "")
                ?? 1_000
        )

        do {
            let report = try await runAcceptance(cycles: cycles)
            try writeArtifact(report)
            #expect(report.status == "pass")
        } catch {
            try? writeFailureArtifact(code: failureCode(for: error), cycles: cycles)
            throw error
        }
    }

    private func runAcceptance(cycles: Int) async throws -> ASRWorkerSoakReport {
        let persistent = try await runPersistentRequests(cycles: cycles)
        let cancellations = try await runCancellationStorm(taskCount: 128)
        let faultModes = [
            "disconnect-first-inference",
            "malformed-first-inference",
            "truncated-first-inference",
        ]
        var faults: [ASRWorkerFaultObservation] = []
        for mode in faultModes {
            faults.append(try await runRecoveringFault(mode: mode, stopsWorker: false))
        }
        faults.append(try await runRecoveringFault(mode: "success", stopsWorker: true))
        let descriptorReuse = try runDescriptorReuseFence(cycles: 256)

        let launched = persistent.launchCount
            + cancellations.launchCount
            + faults.reduce(0) { $0 + $1.launchCount }
        let reaped = persistent.reapedCount
            + cancellations.reapedCount
            + faults.reduce(0) { $0 + $1.reapedCount }
        guard launched == reaped else { throw ASRWorkerSoakFailure.orphanedChild }

        return ASRWorkerSoakReport(
            schemaVersion: 1,
            status: "pass",
            threadSanitizerEnabled: runnerRequest()?.threadSanitizerEnabled ?? false,
            cycles: cycles,
            cancellationTasks: cancellations.taskCount,
            descriptorReuseCycles: descriptorReuse.cycles,
            childLaunchCount: launched,
            childReapedCount: reaped,
            orphanCount: launched - reaped,
            latencyMilliseconds: persistent.latency,
            resourceSamples: persistent.resourceSamples,
            parentFDGrowth: persistent.parentFDGrowth,
            parentRSSGrowthBytes: persistent.parentRSSGrowthBytes,
            parentRSSPeakGrowthBytes: persistent.parentRSSPeakGrowthBytes,
            workerFDGrowth: persistent.workerFDGrowth,
            workerRSSGrowthBytes: persistent.workerRSSGrowthBytes,
            workerRSSPeakGrowthBytes: persistent.workerRSSPeakGrowthBytes,
            cancellationElapsedMilliseconds: cancellations.elapsedMilliseconds,
            cancellationRecoveryElapsedMilliseconds: cancellations.recoveryElapsedMilliseconds,
            cancellationRecoverySucceeded: cancellations.recoverySucceeded,
            cancellationParentFDGrowth: cancellations.parentFDGrowth,
            descriptorParentFDGrowth: descriptorReuse.parentFDGrowth,
            faults: faults,
            transcriptTextRecorded: false
        )
    }

    private func runPersistentRequests(cycles: Int) async throws -> PersistentObservation {
        let fixture = try makeFixture(mode: "success")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let supervisor = makeSupervisor(fixture: fixture, transcriptionDeadline: .seconds(1))

        do {
            try await configure(supervisor)
            let samples = [Float](repeating: 0, count: 160)

            // Move lazy Foundation/JSON allocations outside the resource baseline.
            for _ in 0..<32 {
                let result = try await supervisor.transcribe(samples: samples, languageHint: nil)
                guard result.text.isEmpty, result.words.isEmpty else {
                    throw ASRWorkerSoakFailure.nonEmptyFixtureResult
                }
            }

            let workerPID = try await waitForSingleWorker(in: fixture.processLog)
            let parentBaseline = try processMetrics(processIdentifier: getpid())
            let workerBaseline = try processMetrics(processIdentifier: workerPID)
            var resourceSamples = [
                ASRWorkerResourceSample(
                    cycle: 0,
                    parentFileDescriptors: parentBaseline.fileDescriptors,
                    parentResidentBytes: parentBaseline.residentBytes,
                    workerFileDescriptors: workerBaseline.fileDescriptors,
                    workerResidentBytes: workerBaseline.residentBytes
                ),
            ]
            var latencies: [Double] = []
            latencies.reserveCapacity(cycles)
            let resourceSampleInterval = max(100, cycles / 10)

            for cycle in 1...cycles {
                let started = ContinuousClock.now
                let result = try await supervisor.transcribe(
                    samples: samples,
                    languageHint: cycle.isMultiple(of: 2) ? "ru" : nil
                )
                latencies.append(started.duration(to: .now).milliseconds)
                guard result.text.isEmpty, result.words.isEmpty else {
                    throw ASRWorkerSoakFailure.nonEmptyFixtureResult
                }

                if cycle.isMultiple(of: resourceSampleInterval) || cycle == cycles {
                    let parent = try processMetrics(processIdentifier: getpid())
                    let worker = try processMetrics(processIdentifier: workerPID)
                    resourceSamples.append(
                        ASRWorkerResourceSample(
                            cycle: cycle,
                            parentFileDescriptors: parent.fileDescriptors,
                            parentResidentBytes: parent.residentBytes,
                            workerFileDescriptors: worker.fileDescriptors,
                            workerResidentBytes: worker.residentBytes
                        )
                    )
                }
            }

            let latency = try latencySummary(latencies)
            guard latency.maximum < 250, latency.p99 < 25 else {
                throw ASRWorkerSoakFailure.latencyBudgetExceeded
            }
            let last = try requireLast(resourceSamples)
            let parentFDGrowth = last.parentFileDescriptors - parentBaseline.fileDescriptors
            let workerFDGrowth = last.workerFileDescriptors - workerBaseline.fileDescriptors
            let parentRSSGrowth = Int64(last.parentResidentBytes) - Int64(parentBaseline.residentBytes)
            let workerRSSGrowth = Int64(last.workerResidentBytes) - Int64(workerBaseline.residentBytes)
            let parentPeakRSSGrowth = resourceSamples
                .map { Int64($0.parentResidentBytes) - Int64(parentBaseline.residentBytes) }
                .max() ?? 0
            let workerPeakRSSGrowth = resourceSamples
                .map { Int64($0.workerResidentBytes) - Int64(workerBaseline.residentBytes) }
                .max() ?? 0

            guard parentFDGrowth <= 2, workerFDGrowth <= 2 else {
                throw ASRWorkerSoakFailure.fileDescriptorTrendExceeded
            }
            guard parentPeakRSSGrowth <= 16 * 1_024 * 1_024,
                  workerPeakRSSGrowth <= 4 * 1_024 * 1_024
            else {
                throw ASRWorkerSoakFailure.residentMemoryTrendExceeded
            }

            await supervisor.unload()
            let processIdentifiers = readProcessIdentifiers(from: fixture.processLog)
            let reaped = try await waitForReaped(processIdentifiers)
            guard processIdentifiers.count == 1, reaped == processIdentifiers.count else {
                throw ASRWorkerSoakFailure.orphanedChild
            }

            return PersistentObservation(
                latency: latency,
                resourceSamples: resourceSamples,
                parentFDGrowth: parentFDGrowth,
                parentRSSGrowthBytes: parentRSSGrowth,
                parentRSSPeakGrowthBytes: parentPeakRSSGrowth,
                workerFDGrowth: workerFDGrowth,
                workerRSSGrowthBytes: workerRSSGrowth,
                workerRSSPeakGrowthBytes: workerPeakRSSGrowth,
                launchCount: processIdentifiers.count,
                reapedCount: reaped
            )
        } catch {
            await supervisor.unload()
            throw error
        }
    }

    private func runCancellationStorm(taskCount: Int) async throws -> CancellationObservation {
        let fixture = try makeFixture(mode: "hang-first-inference")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let supervisor = makeSupervisor(fixture: fixture, transcriptionDeadline: .seconds(1))
        let parentFDBaseline = try processMetrics(processIdentifier: getpid()).fileDescriptors

        do {
            try await configure(supervisor)
            let samples = [Float](repeating: 0, count: 160)
            let started = ContinuousClock.now
            let tasks: [Task<ASRResult, any Error>] = (0..<taskCount).map { _ in
                Task {
                    try await supervisor.transcribe(samples: samples, languageHint: nil)
                }
            }

            try await waitUntil(timeout: .seconds(2)) {
                await supervisor.queuedOperationCount >= taskCount - 1
            }
            tasks.forEach { $0.cancel() }

            var cancelled = 0
            for task in tasks {
                switch await task.result {
                case .success:
                    throw ASRWorkerSoakFailure.cancellationUnexpectedSuccess
                case let .failure(error):
                    guard error is CancellationError else {
                        throw ASRWorkerSoakFailure.cancellationUnexpectedError
                    }
                    cancelled += 1
                }
            }
            let elapsed = started.duration(to: .now).milliseconds
            let supervisorIsBusy = await supervisor.isBusy
            guard cancelled == taskCount, elapsed < 2_000, !supervisorIsBusy else {
                throw ASRWorkerSoakFailure.cancellationDidNotDrain
            }

            let recoveryStarted = ContinuousClock.now
            let recovered = try await supervisor.transcribe(samples: samples, languageHint: nil)
            let recoveryElapsed = recoveryStarted.duration(to: .now).milliseconds
            let supervisorRecovered = await supervisor.isPrepared
            guard recovered.text.isEmpty,
                  recovered.words.isEmpty,
                  supervisorRecovered,
                  recoveryElapsed < 1_000
            else {
                throw ASRWorkerSoakFailure.cancellationRecoveryFailed
            }

            await supervisor.unload()
            let processIdentifiers = readProcessIdentifiers(from: fixture.processLog)
            let reaped = try await waitForReaped(processIdentifiers)
            let parentFDAfter = try processMetrics(processIdentifier: getpid()).fileDescriptors
            guard processIdentifiers.count == 2,
                  reaped == processIdentifiers.count,
                  parentFDAfter - parentFDBaseline <= 2
            else {
                throw ASRWorkerSoakFailure.cancellationResourceLeak
            }

            return CancellationObservation(
                taskCount: taskCount,
                elapsedMilliseconds: elapsed,
                recoveryElapsedMilliseconds: recoveryElapsed,
                recoverySucceeded: true,
                parentFDGrowth: parentFDAfter - parentFDBaseline,
                launchCount: processIdentifiers.count,
                reapedCount: reaped
            )
        } catch {
            await supervisor.unload()
            throw error
        }
    }

    private func runRecoveringFault(
        mode: String,
        stopsWorker: Bool
    ) async throws -> ASRWorkerFaultObservation {
        let fixture = try makeFixture(mode: mode)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let supervisor = makeSupervisor(
            fixture: fixture,
            transcriptionDeadline: stopsWorker ? .milliseconds(100) : .milliseconds(500)
        )

        do {
            try await configure(supervisor)
            let firstPID = try await waitForSingleWorker(in: fixture.processLog)
            if stopsWorker {
                guard Darwin.kill(firstPID, SIGSTOP) == 0 else {
                    throw ASRWorkerSoakFailure.signalInjectionFailed
                }
            }

            let started = ContinuousClock.now
            do {
                _ = try await supervisor.transcribe(
                    samples: [Float](repeating: 0, count: 160),
                    languageHint: nil
                )
                throw ASRWorkerSoakFailure.faultUnexpectedSuccess
            } catch is TranscriptionTimeout where stopsWorker {
                // Expected: the watchdog kills the stopped generation.
            } catch let error as ASRWorkerTransportError where !stopsWorker {
                guard error == .disconnected else {
                    throw ASRWorkerSoakFailure.faultUnexpectedError
                }
            }
            let failureElapsed = started.duration(to: .now).milliseconds
            guard failureElapsed < 1_000 else {
                throw ASRWorkerSoakFailure.faultLatencyBudgetExceeded
            }

            try await waitUntil(timeout: .seconds(3)) {
                let processes = readProcessIdentifiers(from: fixture.processLog)
                guard processes.count == 2 else { return false }
                return await supervisor.isPrepared
            }
            let recovered = try await supervisor.transcribe(
                samples: [Float](repeating: 0, count: 160),
                languageHint: nil
            )
            guard recovered.text.isEmpty, recovered.words.isEmpty else {
                throw ASRWorkerSoakFailure.nonEmptyFixtureResult
            }

            await supervisor.unload()
            let processIdentifiers = readProcessIdentifiers(from: fixture.processLog)
            let reaped = try await waitForReaped(processIdentifiers)
            guard processIdentifiers.count == 2,
                  reaped == processIdentifiers.count,
                  Set(processIdentifiers).count == processIdentifiers.count
            else {
                throw ASRWorkerSoakFailure.faultRecoveryGenerationCount
            }

            return ASRWorkerFaultObservation(
                fault: stopsWorker ? "sigstop_timeout" : mode,
                failureElapsedMilliseconds: failureElapsed,
                launchCount: processIdentifiers.count,
                reapedCount: reaped,
                recoverySucceeded: true
            )
        } catch {
            if stopsWorker {
                let processIdentifiers = readProcessIdentifiers(from: fixture.processLog)
                for processIdentifier in processIdentifiers where processIsStopped(processIdentifier) {
                    _ = Darwin.kill(processIdentifier, SIGCONT)
                }
            }
            await supervisor.unload()
            throw error
        }
    }

    private func runDescriptorReuseFence(cycles: Int) throws -> DescriptorReuseObservation {
        let parentFDBaseline = try processMetrics(processIdentifier: getpid()).fileDescriptors
        for _ in 0..<cycles {
            try runDescriptorReuseFenceIteration()
        }
        let parentFDAfter = try processMetrics(processIdentifier: getpid()).fileDescriptors
        let growth = parentFDAfter - parentFDBaseline
        guard growth <= 2 else { throw ASRWorkerSoakFailure.descriptorReuseLeak }
        return DescriptorReuseObservation(cycles: cycles, parentFDGrowth: growth)
    }

    private func runDescriptorReuseFenceIteration() throws {
        var oldPipe: [Int32] = [0, 0]
        guard pipe(&oldPipe) == 0 else { throw ASRWorkerSoakFailure.pipeCreationFailed }
        let reusedDescriptor = fcntl(oldPipe[1], F_DUPFD_CLOEXEC, 200)
        guard reusedDescriptor >= 200 else {
            Darwin.close(oldPipe[0])
            Darwin.close(oldPipe[1])
            throw ASRWorkerSoakFailure.descriptorDuplicationFailed
        }
        let staleWriter: Int32
        do {
            staleWriter = try ASRWorkerDescriptor.duplicate(
                reusedDescriptor,
                suppressSIGPIPE: true
            )
        } catch {
            Darwin.close(oldPipe[0])
            Darwin.close(oldPipe[1])
            Darwin.close(reusedDescriptor)
            throw error
        }
        Darwin.close(oldPipe[0])
        Darwin.close(oldPipe[1])
        Darwin.close(reusedDescriptor)

        var newPipe: [Int32] = [0, 0]
        guard pipe(&newPipe) == 0 else {
            Darwin.close(staleWriter)
            throw ASRWorkerSoakFailure.pipeCreationFailed
        }
        defer {
            Darwin.close(newPipe[0])
            Darwin.close(newPipe[1])
            Darwin.close(reusedDescriptor)
            Darwin.close(staleWriter)
        }
        guard dup2(newPipe[1], reusedDescriptor) == reusedDescriptor else {
            throw ASRWorkerSoakFailure.descriptorDuplicationFailed
        }

        do {
            try ASRWireIO.write(
                ASRWireFrame(kind: .shutdown, requestID: 1, metadata: Data("{}".utf8)),
                to: staleWriter
            )
            throw ASRWorkerSoakFailure.staleDescriptorWriteSucceeded
        } catch is ASRWireError {
            // Expected: the duplicate remains attached to the old dead pipe.
        }

        guard fcntl(newPipe[0], F_SETFL, O_NONBLOCK) == 0 else {
            throw ASRWorkerSoakFailure.descriptorConfigurationFailed
        }
        var byte: UInt8 = 0
        guard Darwin.read(newPipe[0], &byte, 1) == -1, errno == EAGAIN else {
            throw ASRWorkerSoakFailure.staleDescriptorReachedNewGeneration
        }
    }

    private func configure(_ supervisor: ASRWorkerSupervisor) async throws {
        try await supervisor.prepare(modelDirectory: URL(fileURLWithPath: "/tmp/soak-main"))
        try await supervisor.prepareVocabulary(
            modelDirectory: URL(fileURLWithPath: "/tmp/soak-vocabulary"),
            boost: VocabularyBoost(terms: [])
        )
        try await supervisor.warmUpInference()
        guard await supervisor.isPrepared else { throw ASRWorkerSoakFailure.workerNotPrepared }
    }

    private func makeSupervisor(
        fixture: ASRWorkerFixture,
        transcriptionDeadline: Duration
    ) -> ASRWorkerSupervisor {
        ASRWorkerSupervisor(
            executableURL: fixture.executable,
            executableArguments: [fixture.processLog.path, fixture.mode],
            deadlines: ASRWorkerDeadlines(
                hello: .seconds(1),
                preparation: .seconds(1),
                vocabulary: .seconds(1),
                warmup: .seconds(1),
                fileTranscription: .seconds(1),
                transcription: { _ in transcriptionDeadline }
            )
        )
    }

    private func makeFixture(mode: String) throws -> ASRWorkerFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openramble-asr-soak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = Bundle(for: ASRWorkerSoakBundleMarker.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("openramble-asr-worker-test-fixture")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ASRWorkerSoakFailure.fixtureMissing
        }
        return ASRWorkerFixture(
            directory: directory,
            executable: executable,
            processLog: directory.appendingPathComponent("processes.txt"),
            mode: mode
        )
    }

    private func waitForSingleWorker(in processLog: URL) async throws -> Int32 {
        try await waitUntil(timeout: .seconds(2)) {
            readProcessIdentifiers(from: processLog).count == 1
        }
        let identifiers = readProcessIdentifiers(from: processLog)
        guard identifiers.count == 1, let processIdentifier = identifiers.first else {
            throw ASRWorkerSoakFailure.workerLaunchCount
        }
        return processIdentifier
    }

    private func waitUntil(
        timeout: Duration,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ASRWorkerSoakFailure.waitTimedOut
    }

    private func waitForReaped(_ processIdentifiers: [Int32]) async throws -> Int {
        try await waitUntil(timeout: .seconds(3)) {
            processIdentifiers.allSatisfy { !processIsAlive($0) }
        }
        return processIdentifiers.filter { !processIsAlive($0) }.count
    }

    private func readProcessIdentifiers(from url: URL) -> [Int32] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    private func processIsAlive(_ processIdentifier: Int32) -> Bool {
        Darwin.kill(processIdentifier, 0) == 0 || errno != ESRCH
    }

    private func processIsStopped(_ processIdentifier: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        return size == MemoryLayout<proc_bsdinfo>.size && info.pbi_status == UInt32(SSTOP)
    }

    private func processMetrics(processIdentifier: Int32) throws -> ProcessMetrics {
        var info = proc_taskinfo()
        let taskInfoSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTASKINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_taskinfo>.size)
            )
        }
        let estimatedFileDescriptorBytes = proc_pidinfo(
            processIdentifier,
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        guard taskInfoSize == MemoryLayout<proc_taskinfo>.size,
              estimatedFileDescriptorBytes >= 0
        else {
            throw ASRWorkerSoakFailure.processMetricsUnavailable
        }
        // The nil-buffer query reports descriptor-table capacity, not the
        // number of live entries. A high-number descriptor permanently grows
        // that capacity, so using it as the count creates a false leak. The
        // populated call returns only the bytes actually written.
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: max(
                32,
                Int(estimatedFileDescriptorBytes) / MemoryLayout<proc_fdinfo>.size
            )
        )
        let populatedFileDescriptorBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard populatedFileDescriptorBytes >= 0 else {
            throw ASRWorkerSoakFailure.processMetricsUnavailable
        }
        return ProcessMetrics(
            fileDescriptors: Int(populatedFileDescriptorBytes) / MemoryLayout<proc_fdinfo>.size,
            residentBytes: info.pti_resident_size
        )
    }

    private func latencySummary(_ values: [Double]) throws -> ASRWorkerLatencySummary {
        guard !values.isEmpty else { throw ASRWorkerSoakFailure.missingLatencySamples }
        let sorted = values.sorted()
        return ASRWorkerLatencySummary(
            minimum: try requireFirst(sorted),
            p50: percentile(0.50, sorted: sorted),
            p95: percentile(0.95, sorted: sorted),
            p99: percentile(0.99, sorted: sorted),
            maximum: try requireLast(sorted)
        )
    }

    private func percentile(_ percentile: Double, sorted: [Double]) -> Double {
        let index = max(0, min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1))
        return sorted[index]
    }

    private func requireFirst<Value>(_ values: [Value]) throws -> Value {
        guard let first = values.first else { throw ASRWorkerSoakFailure.missingMetricSamples }
        return first
    }

    private func requireLast<Value>(_ values: [Value]) throws -> Value {
        guard let last = values.last else { throw ASRWorkerSoakFailure.missingMetricSamples }
        return last
    }

    private func writeArtifact(_ report: ASRWorkerSoakReport) throws {
        guard let artifactURL else { return }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: artifactURL, options: .atomic)
    }

    private func writeFailureArtifact(code: String, cycles: Int) throws {
        guard let artifactURL else { return }
        let report = ASRWorkerSoakFailureReport(
            schemaVersion: 1,
            status: "fail",
            failureCode: code,
            threadSanitizerEnabled: runnerRequest()?.threadSanitizerEnabled ?? false,
            cycles: cycles,
            transcriptTextRecorded: false
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: artifactURL, options: .atomic)
    }

    private var artifactURL: URL? {
        if let path = ProcessInfo.processInfo.environment["OPENRAMBLE_ASR_SOAK_RESULT_PATH"],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return runnerRequest() == nil ? nil : soakResultURL
    }

    private func runnerRequest() -> ASRWorkerSoakRequest? {
        guard let data = try? Data(contentsOf: soakRequestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ASRWorkerSoakRequest.self, from: data)
    }

    private func failureCode(for error: any Error) -> String {
        if let failure = error as? ASRWorkerSoakFailure { return failure.rawValue }
        if error is CancellationError { return "unexpected_cancellation" }
        return "unexpected_error"
    }
}

private enum ASRWorkerSoakFailure: String, Error, Sendable {
    case cancellationDidNotDrain = "cancellation_did_not_drain"
    case cancellationRecoveryFailed = "cancellation_recovery_failed"
    case cancellationResourceLeak = "cancellation_resource_leak"
    case cancellationUnexpectedError = "cancellation_unexpected_error"
    case cancellationUnexpectedSuccess = "cancellation_unexpected_success"
    case descriptorConfigurationFailed = "descriptor_configuration_failed"
    case descriptorDuplicationFailed = "descriptor_duplication_failed"
    case descriptorReuseLeak = "descriptor_reuse_leak"
    case faultLatencyBudgetExceeded = "fault_latency_budget_exceeded"
    case faultRecoveryGenerationCount = "fault_recovery_generation_count"
    case faultUnexpectedError = "fault_unexpected_error"
    case faultUnexpectedSuccess = "fault_unexpected_success"
    case fileDescriptorTrendExceeded = "file_descriptor_trend_exceeded"
    case fixtureMissing = "fixture_missing"
    case latencyBudgetExceeded = "latency_budget_exceeded"
    case missingLatencySamples = "missing_latency_samples"
    case missingMetricSamples = "missing_metric_samples"
    case nonEmptyFixtureResult = "non_empty_fixture_result"
    case orphanedChild = "orphaned_child"
    case pipeCreationFailed = "pipe_creation_failed"
    case processMetricsUnavailable = "process_metrics_unavailable"
    case residentMemoryTrendExceeded = "resident_memory_trend_exceeded"
    case signalInjectionFailed = "signal_injection_failed"
    case staleDescriptorReachedNewGeneration = "stale_descriptor_reached_new_generation"
    case staleDescriptorWriteSucceeded = "stale_descriptor_write_succeeded"
    case waitTimedOut = "wait_timed_out"
    case workerLaunchCount = "worker_launch_count"
    case workerNotPrepared = "worker_not_prepared"
}

private struct ASRWorkerFixture: Sendable {
    let directory: URL
    let executable: URL
    let processLog: URL
    let mode: String
}

private struct ProcessMetrics: Sendable {
    let fileDescriptors: Int
    let residentBytes: UInt64
}

private struct PersistentObservation: Sendable {
    let latency: ASRWorkerLatencySummary
    let resourceSamples: [ASRWorkerResourceSample]
    let parentFDGrowth: Int
    let parentRSSGrowthBytes: Int64
    let parentRSSPeakGrowthBytes: Int64
    let workerFDGrowth: Int
    let workerRSSGrowthBytes: Int64
    let workerRSSPeakGrowthBytes: Int64
    let launchCount: Int
    let reapedCount: Int
}

private struct CancellationObservation: Sendable {
    let taskCount: Int
    let elapsedMilliseconds: Double
    let recoveryElapsedMilliseconds: Double
    let recoverySucceeded: Bool
    let parentFDGrowth: Int
    let launchCount: Int
    let reapedCount: Int
}

private struct DescriptorReuseObservation: Sendable {
    let cycles: Int
    let parentFDGrowth: Int
}

private struct ASRWorkerLatencySummary: Codable, Sendable {
    let minimum: Double
    let p50: Double
    let p95: Double
    let p99: Double
    let maximum: Double
}

private struct ASRWorkerResourceSample: Codable, Sendable {
    let cycle: Int
    let parentFileDescriptors: Int
    let parentResidentBytes: UInt64
    let workerFileDescriptors: Int
    let workerResidentBytes: UInt64
}

private struct ASRWorkerFaultObservation: Codable, Sendable {
    let fault: String
    let failureElapsedMilliseconds: Double
    let launchCount: Int
    let reapedCount: Int
    let recoverySucceeded: Bool
}

private struct ASRWorkerSoakReport: Codable, Sendable {
    let schemaVersion: Int
    let status: String
    let threadSanitizerEnabled: Bool
    let cycles: Int
    let cancellationTasks: Int
    let descriptorReuseCycles: Int
    let childLaunchCount: Int
    let childReapedCount: Int
    let orphanCount: Int
    let latencyMilliseconds: ASRWorkerLatencySummary
    let resourceSamples: [ASRWorkerResourceSample]
    let parentFDGrowth: Int
    let parentRSSGrowthBytes: Int64
    let parentRSSPeakGrowthBytes: Int64
    let workerFDGrowth: Int
    let workerRSSGrowthBytes: Int64
    let workerRSSPeakGrowthBytes: Int64
    let cancellationElapsedMilliseconds: Double
    let cancellationRecoveryElapsedMilliseconds: Double
    let cancellationRecoverySucceeded: Bool
    let cancellationParentFDGrowth: Int
    let descriptorParentFDGrowth: Int
    let faults: [ASRWorkerFaultObservation]
    let transcriptTextRecorded: Bool
}

private struct ASRWorkerSoakFailureReport: Codable, Sendable {
    let schemaVersion: Int
    let status: String
    let failureCode: String
    let threadSanitizerEnabled: Bool
    let cycles: Int
    let transcriptTextRecorded: Bool
}

private struct ASRWorkerSoakRequest: Codable, Sendable {
    let cycles: Int
    let threadSanitizerEnabled: Bool?
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
