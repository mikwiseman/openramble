@testable import AgentBridge
import AVFoundation
import DictationCore
import LocalASR
import XCTest

final class AgentTranscriptionBrokerTests: XCTestCase {
    private var directory: URL!
    private var bridgeAddress: AgentBridgeSocketAddress!

    override func setUpWithError() throws {
        directory = URL(
            fileURLWithPath: "/tmp/or-broker-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bridgeAddress = try AgentBridgeSocketAddress(
            runtimeDirectory: directory.appending(path: "bridge", directoryHint: .isDirectory)
        )
        try AgentAudioStaging.prepareDirectory(address: bridgeAddress)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDisabledAccessStopsBeforeReadingThePath() async {
        let activity = BrokerActivityProbe()
        let broker = AgentTranscriptionBroker(
            transcriber: LocalTranscriber(engine: BrokerEngine()),
            engineDirectory: directory,
            bridgeAddress: bridgeAddress,
            isEnabled: { false },
            onBusyChanged: activity.record
        )

        let response = await broker.handle(
            request: AgentTranscriptionRequest(stagedFileName: "not-inspected"),
            progress: { _ in }
        )

        guard case let .failure(_, error) = response else {
            return XCTFail("Expected an access error")
        }
        XCTAssertEqual(error.code, .accessDisabled)
        XCTAssertEqual(activity.values, [
            .init(isBusy: true, usedEngine: false),
            .init(isBusy: false, usedEngine: false),
        ])
    }

    func testReturnsRawEngineTextMetricsAndOptionalWords() async throws {
        let audio = try writeWAV(seconds: 0.5)
        let staged = try AgentAudioStaging.stage(sourcePath: audio.path, address: bridgeAddress)
        let broker = AgentTranscriptionBroker(
            transcriber: LocalTranscriber(engine: BrokerEngine()),
            engineDirectory: directory,
            bridgeAddress: bridgeAddress,
            isEnabled: { true }
        )
        let stages = BrokerProgressProbe()

        let response = await broker.handle(
            request: AgentTranscriptionRequest(
                stagedFileName: staged.name,
                languageHint: "en",
                includesTimestamps: true
            ),
            progress: stages.record
        )

        guard case let .result(_, result) = response else {
            return XCTFail("Expected a transcription result, got \(response)")
        }
        XCTAssertEqual(result.text, "raw , engine text")
        XCTAssertEqual(result.audioDurationSeconds, 0.5)
        XCTAssertEqual(result.processingDurationSeconds, 0.02)
        XCTAssertEqual(result.words?.first?.text, "raw")
        XCTAssertGreaterThan(result.totalDurationSeconds, 0)
        XCTAssertGreaterThanOrEqual(result.totalDurationSeconds, result.queueWaitSeconds)
        XCTAssertGreaterThanOrEqual(result.queueWaitSeconds, 0)
        XCTAssertEqual(stages.values, [.queued, .decoding, .transcribing])
    }

    func testLiveDictationPreemptsRunningAgentInference() async throws {
        let audio = try writeWAV(seconds: 0.5)
        let staged = try AgentAudioStaging.stage(sourcePath: audio.path, address: bridgeAddress)
        let engine = BrokerEngine(holdsInference: true)
        let broker = AgentTranscriptionBroker(
            transcriber: LocalTranscriber(engine: engine),
            engineDirectory: directory,
            bridgeAddress: bridgeAddress,
            isEnabled: { true }
        )
        let request = Task {
            await broker.handle(
                request: AgentTranscriptionRequest(stagedFileName: staged.name),
                progress: { _ in }
            )
        }
        await engine.waitUntilInferenceStarts()

        broker.beginInteractiveWork()
        let response = await request.value
        broker.endInteractiveWork()

        guard case let .failure(_, error) = response else {
            return XCTFail("Expected preemption")
        }
        XCTAssertEqual(error.code, .preemptedByDictation)
        XCTAssertTrue(error.isRetryable)
    }

    private func writeWAV(seconds: Double) throws -> URL {
        let url = directory.appending(path: "voice-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let frames = AVAudioFrameCount(seconds * 16_000)
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for index in 0..<Int(frames) {
                buffer.floatChannelData?[0][index] = sin(Float(index) * 0.04) * 0.2
            }
            try file.write(from: buffer)
        }
        return url
    }
}

private actor BrokerEngine: ASREngineAdapting {
    private let holdsInference: Bool
    private var started = false

    init(holdsInference: Bool = false) {
        self.holdsInference = holdsInference
    }

    func loadModels(from directory: URL) async throws {}

    func transcribe(samples: [Float]) async throws -> ASRResult {
        started = true
        if holdsInference {
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        return ASRResult(
            text: "raw , engine text",
            words: [.init(text: "raw", start: 0, end: 0.2, confidence: 0.9)],
            audioDuration: 0.5,
            processingDuration: 0.02
        )
    }

    func unload() async {}

    func waitUntilInferenceStarts() async {
        while !started { await Task.yield() }
    }
}

private final class BrokerProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentBridgeProgress] = []

    var values: [AgentBridgeProgress] { lock.withLock { storage } }
    func record(_ value: AgentBridgeProgress) { lock.withLock { storage.append(value) } }
}

private final class BrokerActivityProbe: @unchecked Sendable {
    struct Event: Equatable {
        let isBusy: Bool
        let usedEngine: Bool
    }

    private let lock = NSLock()
    private var storage: [Event] = []

    var values: [Event] { lock.withLock { storage } }
    func record(isBusy: Bool, usedEngine: Bool) {
        lock.withLock { storage.append(.init(isBusy: isBusy, usedEngine: usedEngine)) }
    }
}
