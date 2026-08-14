import ASRWorkerProtocol
import Darwin
import DictationCore
import Foundation
import LocalASR
import Testing

private final class ASRWorkerTestBundleMarker: NSObject {}

@Suite("ASR worker supervision", .serialized)
struct ASRWorkerSupervisorTests {
    @Test("generation fencing kills only the owned exact PID")
    func exactPIDKill() throws {
        let owned = try launchSleepProcess()
        let neighbor = try launchSleepProcess()
        defer { killAndReapIfNeeded(neighbor.process) }

        let holder = ASRWorkerProcessHolder()
        holder.install(
            .init(
                process: owned.process,
                input: owned.input,
                output: owned.output,
                generation: 17
            )
        )

        #expect(holder.kill(generation: 16) == nil)
        #expect(owned.process.isRunning)
        #expect(neighbor.process.isRunning)

        let killed = try #require(holder.kill(generation: 17))
        #expect(killed.processIdentifier == owned.process.processIdentifier)
        killed.process.waitUntilExit()
        #expect(killed.process.terminationReason == .uncaughtSignal)
        #expect(killed.process.terminationStatus == SIGKILL)
        #expect(holder.snapshot()?.generation == nil)

        // A neighboring process with the same executable remains alive. This
        // guards against accidental pkill/killall-style recovery.
        #expect(Darwin.kill(neighbor.process.processIdentifier, 0) == 0)
    }

    @Test("stale I/O cannot follow a descriptor number reused by a new generation")
    func descriptorReuseFence() throws {
        var oldPipe: [Int32] = [0, 0]
        #expect(pipe(&oldPipe) == 0)
        let reusedDescriptorNumber = fcntl(oldPipe[1], F_DUPFD_CLOEXEC, 100)
        #expect(reusedDescriptorNumber >= 100)
        let staleWriter = try ASRWorkerDescriptor.duplicate(
            reusedDescriptorNumber,
            suppressSIGPIPE: true
        )
        Darwin.close(oldPipe[0])
        Darwin.close(oldPipe[1])
        Darwin.close(reusedDescriptorNumber)
        defer { Darwin.close(staleWriter) }

        var newPipe: [Int32] = [0, 0]
        #expect(pipe(&newPipe) == 0)
        defer {
            Darwin.close(newPipe[0])
            Darwin.close(newPipe[1])
            Darwin.close(reusedDescriptorNumber)
        }
        #expect(dup2(newPipe[1], reusedDescriptorNumber) == reusedDescriptorNumber)

        #expect(throws: ASRWireError.self) {
            try ASRWireIO.write(
                ASRWireFrame(kind: .shutdown, requestID: 7, metadata: Data("{}".utf8)),
                to: staleWriter
            )
        }

        // A stale raw descriptor would have written a frame into this new
        // generation. The owned duplicate remains attached to the dead pipe.
        #expect(fcntl(newPipe[0], F_SETFL, O_NONBLOCK) == 0)
        var byte: UInt8 = 0
        #expect(Darwin.read(newPipe[0], &byte, 1) == -1)
        #expect(errno == EAGAIN)
    }

    @Test("cancelling queued preparation cannot mutate a later worker generation")
    func queuedPreparationCancellation() async throws {
        let fixture = try makeHangingWorker(mode: "hang-inference")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let supervisor = ASRWorkerSupervisor(
            executableURL: fixture.executable,
            executableArguments: [fixture.processLog.path, fixture.mode]
        )
        try await supervisor.acquireOperation()

        let queued = Task {
            try await supervisor.prepare(
                modelDirectory: URL(fileURLWithPath: "/tmp/cancelled-model")
            )
        }
        for _ in 0..<100 {
            if await supervisor.queuedOperationCount == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await supervisor.queuedOperationCount == 1)
        queued.cancel()
        await supervisor.releaseOperation()

        do {
            try await queued.value
            Issue.record("cancelled waiter unexpectedly acquired the operation gate")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("unexpected queued-operation error: \(type(of: error))")
        }

        #expect(await supervisor.isBusy == false)
        try await supervisor.prepare(
            modelDirectory: URL(fileURLWithPath: "/tmp/active-model")
        )
        await supervisor.unload()
        #expect(await supervisor.isBusy == false)

        let processIdentifiers = readProcessIdentifiers(from: fixture.processLog)
        #expect(processIdentifiers.count == 1)
        let processIdentifier = try #require(processIdentifiers.first)
        #expect(Darwin.kill(processIdentifier, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("a missing worker fails closed without an in-process fallback")
    func missingWorkerFailsClosed() async {
        let supervisor = ASRWorkerSupervisor(
            executableURL: URL(fileURLWithPath: "/does-not-exist/openramble-asr-worker")
        )
        do {
            try await supervisor.prepare(modelDirectory: URL(fileURLWithPath: "/tmp/model"))
            Issue.record("missing worker unexpectedly prepared")
        } catch let error as ASRWorkerTransportError {
            #expect(error == .executableMissing)
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
    }

    @Test("short dictation watchdog has a bounded floor and ceiling")
    func transcriptionDeadlineBounds() {
        let deadlines = ASRWorkerDeadlines()
        #expect(deadlines.transcription(0) == .milliseconds(2_500))
        #expect(deadlines.transcription(15) == .milliseconds(2_500))
        #expect(deadlines.transcription(90) == .milliseconds(2_500))
        #expect(deadlines.transcription(180) == .milliseconds(5_500))
        #expect(
            deadlines.transcription(180)
                < TranscriptionDeadline.deadline(forAudioDuration: 180)
        )
    }

    @Test("a preparation timeout is never retried")
    func preparationTimeoutFailsOnce() async throws {
        let fixture = try makeHangingWorker(mode: "hang-prepare")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let supervisor = ASRWorkerSupervisor(
            executableURL: fixture.executable,
            executableArguments: [fixture.processLog.path, fixture.mode],
            deadlines: ASRWorkerDeadlines(
                hello: .seconds(1),
                preparation: .milliseconds(100),
                vocabulary: .seconds(1),
                warmup: .seconds(1),
                fileTranscription: .seconds(1),
                transcription: { _ in .seconds(1) }
            )
        )

        let started = ContinuousClock.now
        do {
            try await supervisor.prepare(modelDirectory: URL(fileURLWithPath: "/tmp/main-model"))
            Issue.record("hanging preparation unexpectedly returned")
        } catch let error as ASRWorkerTransportError {
            #expect(error == .requestTimedOut)
        } catch {
            Issue.record("unexpected preparation error: \(type(of: error))")
        }
        // The exact sleep wakeup is scheduler-dependent on a loaded CI host;
        // the one-process assertion below is the retry oracle. This bound only
        // guards against accidentally waiting for multiple long budgets.
        #expect(started.duration(to: .now) < .seconds(2))

        await supervisor.unload()
        let processIdentifiers = readProcessIdentifiers(from: fixture.processLog)
        #expect(processIdentifiers.count == 1)
        let processIdentifier = try #require(processIdentifiers.first)
        #expect(Darwin.kill(processIdentifier, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("a pre-inference disconnect is retried exactly once")
    func preparationDisconnectRetriesOnce() async throws {
        let fixture = try makeHangingWorker(mode: "disconnect-first-prepare")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let supervisor = ASRWorkerSupervisor(
            executableURL: fixture.executable,
            executableArguments: [fixture.processLog.path, fixture.mode],
            deadlines: ASRWorkerDeadlines(
                hello: .seconds(1),
                preparation: .seconds(1),
                vocabulary: .seconds(1),
                warmup: .seconds(1),
                fileTranscription: .seconds(1),
                transcription: { _ in .seconds(1) }
            )
        )

        try await supervisor.prepare(modelDirectory: URL(fileURLWithPath: "/tmp/main-model"))
        await supervisor.unload()

        let processIdentifiers = readProcessIdentifiers(from: fixture.processLog)
        #expect(processIdentifiers.count == 2)
        for processIdentifier in processIdentifiers {
            #expect(Darwin.kill(processIdentifier, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test("timeout kills, fails fast, then restores the full worker generation")
    func timeoutRecovery() async throws {
        let fixture = try makeHangingWorker(mode: "hang-inference")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let deadlines = ASRWorkerDeadlines(
            hello: .seconds(3),
            preparation: .seconds(1),
            vocabulary: .seconds(1),
            warmup: .seconds(1),
            fileTranscription: .seconds(1),
            transcription: { _ in .milliseconds(100) }
        )
        let supervisor = ASRWorkerSupervisor(
            executableURL: fixture.executable,
            executableArguments: [fixture.processLog.path, fixture.mode],
            deadlines: deadlines
        )

        try await supervisor.prepare(modelDirectory: URL(fileURLWithPath: "/tmp/main-model"))
        try await supervisor.prepareVocabulary(
            modelDirectory: URL(fileURLWithPath: "/tmp/vocabulary-model"),
            boost: VocabularyBoost(terms: [])
        )
        try await supervisor.warmUpInference()
        #expect(await supervisor.isPrepared)

        let started = ContinuousClock.now
        do {
            _ = try await supervisor.transcribe(
                samples: [Float](repeating: 0, count: 1_600),
                languageHint: nil
            )
            Issue.record("hanging inference unexpectedly returned")
        } catch is TranscriptionTimeout {
            // Expected.
        } catch {
            Issue.record("unexpected timeout error: \(type(of: error))")
        }
        #expect(started.duration(to: .now) < .seconds(1))

        var processIdentifiers: [Int32] = []
        for _ in 0..<200 {
            processIdentifiers = readProcessIdentifiers(from: fixture.processLog)
            if processIdentifiers.count == 2, await supervisor.isPrepared { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(processIdentifiers.count == 2)
        let first = try #require(processIdentifiers.first)
        let second = try #require(processIdentifiers.last)
        #expect(first != second)
        #expect(Darwin.kill(first, 0) == -1)
        #expect(errno == ESRCH)
        #expect(Darwin.kill(second, 0) == 0)
        #expect(await supervisor.isPrepared)

        await supervisor.unload()
        #expect(Darwin.kill(second, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("an idle ready worker death restores a fully warm generation before the next request")
    func idleReadyWorkerDeathRecoversProactively() async throws {
        let fixture = try makeHangingWorker(mode: "exit-after-ready")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let supervisor = ASRWorkerSupervisor(
            executableURL: fixture.executable,
            executableArguments: [fixture.processLog.path, fixture.mode],
            deadlines: ASRWorkerDeadlines(
                hello: .seconds(1),
                preparation: .seconds(1),
                vocabulary: .seconds(1),
                warmup: .seconds(1),
                fileTranscription: .seconds(1),
                transcription: { _ in .seconds(1) }
            )
        )

        try await supervisor.prepare(modelDirectory: URL(fileURLWithPath: "/tmp/main-model"))
        try await supervisor.prepareVocabulary(
            modelDirectory: URL(fileURLWithPath: "/tmp/vocabulary-model"),
            boost: VocabularyBoost(terms: [])
        )
        try await supervisor.warmUpInference()

        var processIdentifiers: [Int32] = []
        for _ in 0..<300 {
            processIdentifiers = readProcessIdentifiers(from: fixture.processLog)
            if processIdentifiers.count == 2, await supervisor.isPrepared { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(processIdentifiers.count == 2)
        #expect(await supervisor.isPrepared)
        let first = try #require(processIdentifiers.first)
        let second = try #require(processIdentifiers.last)
        #expect(first != second)
        #expect(Darwin.kill(first, 0) == -1)
        #expect(errno == ESRCH)
        #expect(Darwin.kill(second, 0) == 0)

        await supervisor.unload()
        #expect(Darwin.kill(second, 0) == -1)
        #expect(errno == ESRCH)
    }

    private func launchSleepProcess() throws -> (
        process: Process,
        input: FileHandle,
        output: FileHandle
    ) {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        return (process, inputPipe.fileHandleForWriting, outputPipe.fileHandleForReading)
    }

    private func killAndReapIfNeeded(_ process: Process) {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func makeHangingWorker(mode: String) throws -> (
        directory: URL,
        executable: URL,
        processLog: URL,
        mode: String
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openramble-asr-worker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let processLog = directory.appendingPathComponent("processes.txt")
        let executable = Bundle(for: ASRWorkerTestBundleMarker.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("openramble-asr-worker-test-fixture")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return (directory, executable, processLog, mode)
    }

    private func readProcessIdentifiers(from url: URL) -> [Int32] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }
}
