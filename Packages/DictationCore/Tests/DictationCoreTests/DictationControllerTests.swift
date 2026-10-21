import XCTest
@testable import DictationCore

// MARK: - False edges of the system

actor FakeCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    private var startError: AudioCaptureError?
    private var bufferedSamples: [Float]?
    private let file = URL(fileURLWithPath: "/tmp/fake-take.wav")

    func setStartError(_ error: AudioCaptureError?) { startError = error }
    func setBufferedSamples(_ samples: [Float]?) { bufferedSamples = samples }

    func startRecording() async throws -> URL {
        startCount += 1
        if let startError { throw startError }
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        return (file, 2.0)
    }

    func takeBufferedSamples() async -> [Float]? {
        defer { bufferedSamples = nil }
        return bufferedSamples
    }

    func abortRecording() async { abortCount += 1 }
}

/// A capture in which the first frame of sound does not come immediately, like the real one.
///
/// The real engine returns from `startRecording` at startup, and hear
/// starts after about 0.13 s. Everything that happens in this gap
/// the fake capture completely concealed without delay.
actor SlowFirstFrameCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    /// `nil` - the device is silent and there will be no frame at all (AirPods in a drawer).
    private let firstFrame: Gate?
    private let file = URL(fileURLWithPath: "/tmp/slow-first-frame.wav")

    init(firstFrame: Gate?) { self.firstFrame = firstFrame }

    func startRecording() async throws -> URL {
        startCount += 1
        return file
    }

    func waitForFirstFrame() async -> Bool {
        guard let firstFrame else {
            // Silent device: wait until recording finishes outside.
            while stopCount == 0, abortCount == 0 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        await firstFrame.pass()
        return true
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        return (file, 2.0)
    }

    func abortRecording() async { abortCount += 1 }
}

/// A stopped capture whose PCM, readable WAV and durable WAV are three
/// independently controllable milestones.
actor MilestoneCapture: AudioCapturing {
    let fileURL: URL
    private let samples: [Float]?
    private let duration: TimeInterval
    private let readable: Gate
    private let durable: Gate

    init(
        samples: [Float]?,
        duration: TimeInterval = 2,
        readable: Gate,
        durable: Gate
    ) {
        self.samples = samples
        self.duration = duration
        self.readable = readable
        self.durable = durable
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "milestone-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data([0]))
    }

    func startRecording() async throws -> URL { fileURL }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        let recording = try await freezeRecording()
        return (try await recording.durableURL(), duration)
    }

    func freezeRecording() async throws -> CapturedRecording {
        let fileURL = fileURL
        let readableGate = readable
        let durableGate = durable
        let readableTask = Task<URL, Error> {
            await readableGate.pass()
            return fileURL
        }
        let durableTask = Task<URL, Error> {
            _ = try await readableTask.value
            await durableGate.pass()
            return fileURL
        }
        return CapturedRecording(
            url: fileURL,
            duration: duration,
            samples: samples,
            readableTask: readableTask,
            durableTask: durableTask
        )
    }

    func abortRecording() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Disk finalization failed, but the bounded PCM can produce a complete
/// replacement file for the retry path.
actor RebuildableFailedDiskCapture: AudioCapturing {
    let rawURL: URL
    let rebuiltURL: URL
    private let samples: [Float]

    init(directory: URL, samples: [Float]) {
        self.samples = samples
        rawURL = directory.appending(path: "truncated.wav")
        rebuiltURL = directory.appending(path: "rebuilt.wav")
        FileManager.default.createFile(atPath: rawURL.path, contents: Data("truncated".utf8))
        FileManager.default.createFile(atPath: rebuiltURL.path, contents: Data("complete".utf8))
    }

    func startRecording() async throws -> URL { rawURL }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        throw AudioCaptureError.writeFailed("disk pipeline failed")
    }

    func freezeRecording() async throws -> CapturedRecording {
        let rawURL = rawURL
        let rebuiltURL = rebuiltURL
        let failed = Task<URL, Error> {
            throw AudioCaptureError.writeFailed("disk pipeline failed")
        }
        return CapturedRecording(
            url: rawURL,
            duration: 2,
            samples: samples,
            readableTask: failed,
            durableTask: failed,
            materializeRecovery: { rebuiltURL }
        )
    }

    func abortRecording() async {
        try? FileManager.default.removeItem(at: rawURL)
    }
}

actor StalledRecoveryStore: RecordingRecoveryStoring {
    private let gate: Gate

    init(gate: Gate) {
        self.gate = gate
    }

    func preserve(_ source: URL) async throws -> URL? {
        await gate.pass()
        return source
    }
}

private struct ExpectedRecognitionFailure: Error {}

actor FakeInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var returnPresses = 0
    private(set) var targets: [TargetApplication?] = []
    private var error: TextInsertionError?
    nonisolated(unsafe) var frontmost: TargetApplication?

    func setError(_ error: TextInsertionError?) { self.error = error }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        if let error { throw error }
        insertedTexts.append(text)
        targets.append(target)
    }

    func pressReturn() async throws {
        if let error { throw error }
        returnPresses += 1
    }

    nonisolated func frontmostApplication() -> TargetApplication? { frontmost }
}

/// Sends ⌘V that nobody reads, and waits for the read until told to stop,
/// the way the real inserter does.
private final class ReadWaitingInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false
    private var ended = false

    var isWaiting: Bool { lock.withLock { waiting } }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        lock.withLock { waiting = true }
        for _ in 0..<1000 where !lock.withLock({ ended }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TextInsertionError.pasteNotRead
    }

    func endTheReadWait() {
        lock.withLock { if waiting { ended = true } }
    }

    func pressReturn() async throws {}
    func frontmostApplication() -> TargetApplication? { nil }
}

/// A paste the target reads 18 ms after ⌘V, held to the restore floor the
/// way the real inserter holds it: the text is already in place while the
/// insertion still has 250 ms to go.
private final class LandedPasteInserter: TextInserting, @unchecked Sendable {
    private let lock = NSLock()
    private var pastes: [ContinuousClock.Instant] = []

    var lastPaste: ContinuousClock.Instant? { lock.withLock { pastes.last } }
    var pasteCount: Int { lock.withLock { pastes.count } }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        _ = try await insertReportingMarks(text, into: target)
    }

    func insertReportingMarks(
        _ text: String,
        into target: TargetApplication?
    ) async throws -> InsertionMarks {
        let paste = ContinuousClock.now
        lock.withLock { pastes.append(paste) }
        try await Task.sleep(until: paste + .milliseconds(250))
        return InsertionMarks(
            pasteDispatchedAt: paste,
            clipboardRestoredAt: .now,
            firstReadAt: paste + .milliseconds(18)
        )
    }

    func pressReturn() async throws {}
    func frontmostApplication() -> TargetApplication? { nil }
}

actor FakeOverlay: OverlayPresenting {
    private(set) var presentedStates: [DictationState] = []
    private(set) var dismissCount = 0
    private(set) var notices: [DictationNotice] = []

    func present(_ state: DictationState, elapsed: TimeInterval) async {
        presentedStates.append(state)
    }
    func dismiss() async { dismissCount += 1 }
    func presentNotice(_ notice: DictationNotice) async { notices.append(notice) }
}

actor FakeSounds: Sounding {
    private(set) var attentionPlays = 0
    func playAttention() async { attentionPlays += 1 }
}

private actor TranscriptionRouteLog {
    private(set) var fileCalls = 0
    private(set) var sampleCalls = 0
    private(set) var samples: [Float] = []

    func recordFile() { fileCalls += 1 }
    func recordSamples(_ value: [Float]) {
        sampleCalls += 1
        samples = value
    }
}

// MARK: - Tests

@MainActor
final class DictationControllerTests: XCTestCase {
    private var capture: FakeCapture!
    private var inserter: FakeInserter!
    private var overlay: FakeOverlay!
    private var sounds: FakeSounds!

    override func setUp() async throws {
        capture = FakeCapture()
        inserter = FakeInserter()
        overlay = FakeOverlay()
        sounds = FakeSounds()
    }

    private func makeController(
        recognized: String = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}",
        transcribeDelay: Duration = .zero,
        transcribeError: Error? = nil,
        replacements: [DictionaryReplacement] = [],
        inserter: (any TextInserting)? = nil
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in
                if transcribeDelay > .zero { try await Task.sleep(for: transcribeDelay) }
                if let transcribeError { throw transcribeError }
                return ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter ?? self.inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { _ in TextPipeline(replacements: replacements) }
        )
    }

    /// Let the controller's background tasks finish their work.
    /// Give the overlay's independently-scheduled presents time to land.
    private func waitForPresentedStates(atLeast count: Int) async -> [DictationState] {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let states = await overlay.presentedStates
            if states.count >= count { return states }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await overlay.presentedStates
    }

    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testRecognizerUsesCaptureBufferWithoutReopeningTheWAV() async throws {
        let expected: [Float] = [0.1, -0.2, 0.3]
        await capture.setBufferedSamples(expected)
        let route = TranscriptionRouteLog()
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in
                await route.recordFile()
                return ASRResult(text: "file", audioDuration: 2, processingDuration: 0.1)
            },
            transcribeSamples: { samples in
                await route.recordSamples(samples)
                return ASRResult(text: "buffer", audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let fileCalls = await route.fileCalls
        let sampleCalls = await route.sampleCalls
        let delivered = await route.samples
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(fileCalls, 0)
        XCTAssertEqual(sampleCalls, 1)
        XCTAssertEqual(delivered, expected)
        XCTAssertEqual(inserted, ["Buffer"])
    }

    func testPCMRecognitionAndInsertionDoNotWaitForReadableOrDurableWAV() async throws {
        let readable = Gate()
        let durable = Gate()
        let milestone = MilestoneCapture(
            samples: [0.1, -0.2, 0.3],
            readable: readable,
            durable: durable
        )
        let controller = DictationController(
            capture: milestone,
            transcribe: { _ in XCTFail("PCM path must not open WAV"); return ASRResult(text: "file", audioDuration: 2, processingDuration: 0.1) },
            transcribeSamples: { _ in ASRResult(text: "fast", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(controller.state, .idle, "file milestones must not hold the UI")
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["Fast"])
        await readable.open()
        await durable.open()
    }

    func testLongFileFallbackWaitsForReadableButNotDurableWAV() async throws {
        let readable = Gate()
        let durable = Gate()
        let milestone = MilestoneCapture(
            samples: nil,
            duration: 301,
            readable: readable,
            durable: durable
        )
        let route = TranscriptionRouteLog()
        let controller = DictationController(
            capture: milestone,
            transcribe: { _ in
                await route.recordFile()
                return ASRResult(text: "long", audioDuration: 301, processingDuration: 0.2)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle(4)
        let callsBeforeReadable = await route.fileCalls
        XCTAssertEqual(callsBeforeReadable, 0)
        XCTAssertEqual(controller.state, .transcribing)

        await readable.open()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        let callsAfterReadable = await route.fileCalls
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(callsAfterReadable, 1)
        XCTAssertEqual(inserted, ["Long"])
        XCTAssertEqual(controller.state, .idle, "fsync must remain outside the file fallback path")
        await durable.open()
    }

    func testUnreadableLongRecordingTimesOutAndLeavesRawTakeForRecovery() async throws {
        let readable = Gate()
        let durable = Gate()
        let milestone = MilestoneCapture(
            samples: nil,
            duration: 301,
            readable: readable,
            durable: durable
        )
        var notices: [DictationNotice] = []
        let controller = DictationController(
            capture: milestone,
            transcribe: { _ in XCTFail("unreadable WAV must not reach ASR"); return ASRResult(text: "", audioDuration: 0, processingDuration: 0) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            recordingReadableDeadline: .milliseconds(80)
        )
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(notices.contains { $0.message.contains("unfinished file") })
        let fileURL = milestone.fileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await readable.open()
        await durable.open()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testStalledRecoveryMoveCannotHoldTheUIForever() async throws {
        let readable = Gate()
        let durable = Gate()
        let recoveryGate = Gate()
        let milestone = MilestoneCapture(
            samples: [0.1, 0.2],
            readable: readable,
            durable: durable
        )
        await readable.open()
        await durable.open()
        var notices: [DictationNotice] = []
        let controller = DictationController(
            capture: milestone,
            transcribe: { _ in throw ExpectedRecognitionFailure() },
            transcribeSamples: { _ in throw ExpectedRecognitionFailure() },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            recordingRecovery: StalledRecoveryStore(gate: recoveryGate),
            recordingPreserveDeadline: .milliseconds(50)
        )
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<300 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(notices.contains { $0.message.contains("automatic recovery") })

        // Let the deliberately cancellation-deaf fake finish so the test does
        // not leave an unstructured waiter behind.
        await recoveryGate.open()
        try? FileManager.default.removeItem(at: milestone.fileURL)
    }

    func testRecognitionFailurePreservesCompletePCMRebuildInsteadOfTruncatedWAV() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pcm-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let recoveryDirectory = directory.appending(path: "Recovery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = RebuildableFailedDiskCapture(
            directory: directory,
            samples: [0.1, 0.2, 0.3]
        )
        var notices: [DictationNotice] = []
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in throw ExpectedRecognitionFailure() },
            transcribeSamples: { _ in throw ExpectedRecognitionFailure() },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            recordingRecovery: RecordingRecoveryStore(directory: recoveryDirectory)
        )
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<300 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }

        let recoveryURL = try XCTUnwrap(notices.last?.recoveryAudio)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), Data("complete".utf8))
        // Raw cleanup is deliberately non-gating: its durable delete intent
        // must not hold the controller in Transcribing on slow storage.
        let cleanupDeadline = ContinuousClock.now + .seconds(2)
        while FileManager.default.fileExists(atPath: capture.rawURL.path),
              ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.rawURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.rebuiltURL.path))
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Normal path

    func testFullFlowInsertsProcessedText() async throws {
        let controller = makeController(recognized: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}")
        // The acknowledgement promise lives here, not on the overlay: the
        // controller publishes .preparing the instant the key goes down, and
        // .listening once capture is live. The overlay queue deliberately
        // coalesces to the newest state — showing a stale one would be worse
        // than showing one fewer — so asserting its buffer would be asserting
        // a guarantee the design does not make.
        var published: [DictationState] = []
        controller.onStateChange = { published.append($0) }
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(
            Array(published.prefix(2)),
            [.preparing, .listening],
            "the hotkey must receive immediate visual acknowledgement before capture is ready"
        )
        let presented = await overlay.presentedStates
        XCTAssertFalse(presented.isEmpty, "the overlay still hears about the session")

        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"], "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043F}\u{0440}\u{043E}\u{0439}\u{0442}\u{0438} \u{0447}\u{0435}\u{0440}\u{0435}\u{0437} \u{043E}\u{0431}\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{043A}\u{0443}")
        XCTAssertEqual(controller.state, .idle, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{044F} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{0442}\u{0430}")
    }

    func testRecordingReachesListeningWithoutASound() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)

        await settle()

        XCTAssertEqual(controller.state, .listening)
        // The panel is the signal that recording started; a chime here would
        // be a second, louder copy of what the person can already see.
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 0)
    }

    func testSlowFirstFrameNeitherHangsTheSessionNorSounds() async throws {
        // The microphone takes 0.13–0.14 s on M4 Pro to deliver its first
        // frame (docs/benchmarks.md). The panel must promise "speak" without
        // waiting for it, the session must survive the wait, and nothing may
        // be played on the way — a working dictation is silent.
        let frame = Gate()
        let slowCapture = SlowFirstFrameCapture(firstFrame: frame)
        let controller = DictationController(
            capture: slowCapture,
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        XCTAssertEqual(controller.state, .listening, "\u{041F}\u{0430}\u{043D}\u{0435}\u{043B}\u{044C} \u{043F}\u{043E}\u{043A}\u{0430}\u{0437}\u{044B}\u{0432}\u{0430}\u{0435}\u{0442} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0441}\u{0440}\u{0430}\u{0437}\u{0443}")
        let beforeFrame = await sounds.attentionPlays
        XCTAssertEqual(beforeFrame, 0)

        await frame.open()
        await settle()

        XCTAssertEqual(controller.state, .listening, "the arriving frame must not disturb the session")
        let afterFrame = await sounds.attentionPlays
        XCTAssertEqual(afterFrame, 0, "nothing about a healthy recording is worth a sound")
    }

    func testSilentDeviceDoesNotHangTheSession() async throws {
        // There are no frames at all - the wrong microphone was selected. Promise "speak" here
        // it’s not possible, but it’s also impossible to suspend the session by waiting: stopping is required
        // work, otherwise the microphone will remain on until the hour limit.
        let silentCapture = SlowFirstFrameCapture(firstFrame: nil)
        let controller = DictationController(
            capture: silentCapture,
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 0, "\u{041C}\u{043E}\u{043B}\u{0447}\u{0430}\u{0449}\u{0435}\u{0435} \u{0443}\u{0441}\u{0442}\u{0440}\u{043E}\u{0439}\u{0441}\u{0442}\u{0432}\u{043E} \u{043D}\u{0435} \u{0434}\u{0430}\u{0451}\u{0442} \u{043F}\u{043E}\u{0432}\u{043E}\u{0434}\u{0430} \u{0437}\u{0432}\u{0430}\u{0442}\u{044C} \u{0433}\u{043E}\u{0432}\u{043E}\u{0440}\u{0438}\u{0442}\u{044C}")

        controller.stop()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle, "\u{041E}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043A}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043F}\u{0440}\u{043E}\u{0439}\u{0442}\u{0438} \u{0438} \u{0431}\u{0435}\u{0437} \u{0435}\u{0434}\u{0438}\u{043D}\u{043E}\u{0433}\u{043E} \u{043A}\u{0430}\u{0434}\u{0440}\u{0430}")
        let stops = await silentCapture.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testQuickTapStopsWithoutWaitingForTheFirstFrame() async throws {
        // Pressed and released before the engine heard: wait for a frame for the sake of sound
        // there is no need to “speak” in an already completed recording, but in a silent
        // on the device, this wait would leave the microphone on.
        let silentCapture = SlowFirstFrameCapture(firstFrame: nil)
        let controller = DictationController(
            capture: silentCapture,
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        controller.stop()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle, "\u{041E}\u{0442}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{043D}\u{043E}\u{0435} \u{043E}\u{0442}\u{043F}\u{0443}\u{0441}\u{043A}\u{0430}\u{043D}\u{0438}\u{0435} \u{043D}\u{0435} \u{0436}\u{0434}\u{0451}\u{0442} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0433}\u{043E} \u{043A}\u{0430}\u{0434}\u{0440}\u{0430}")
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 0)
    }

    // MARK: Release before ready

    func testReleaseBeforeCaptureStartsIsNotLost() async throws {
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        // The key was released while the engine was still rising - the most common gesture
        // for a short phrase.
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1, "\u{041E}\u{0442}\u{043F}\u{0443}\u{0441}\u{043A}\u{0430}\u{043D}\u{0438}\u{0435} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043F}\u{043E}\u{0442}\u{0435}\u{0440}\u{044F}\u{0442}\u{044C}\u{0441}\u{044F}")
        XCTAssertEqual(controller.state, .idle, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0451}\u{043D}\u{043D}\u{043E}\u{0439}")
    }

    // MARK: Uniqueness of finalization

    func testRepeatedStopInsertsOnlyOnce() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.stop()
        controller.stop()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F} \u{0440}\u{043E}\u{0432}\u{043D}\u{043E} \u{043E}\u{0434}\u{0438}\u{043D} \u{0440}\u{0430}\u{0437}")
    }

    func testSecondBeginWhileBusyIsIgnored() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        let starts = await capture.startCount
        XCTAssertEqual(starts, 1, "\u{0412}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{044F} \u{043F}\u{043E}\u{0432}\u{0435}\u{0440}\u{0445} \u{0437}\u{0430}\u{043D}\u{044F}\u{0442}\u{043E}\u{0439} \u{043D}\u{0435} \u{043D}\u{0430}\u{0447}\u{0438}\u{043D}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F}")
    }

    // MARK: Cancel

    func testCancelDuringRecordingNeverInserts() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.cancel()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0435}\u{0442}\u{0441}\u{044F}")
        let aborts = await capture.abortCount
        XCTAssertEqual(aborts, 1, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0431}\u{044B}\u{0442}\u{044C} \u{043F}\u{0440}\u{0435}\u{0440}\u{0432}\u{0430}\u{043D}\u{0430}, \u{0430} \u{0444}\u{0430}\u{0439}\u{043B} \u{0432}\u{044B}\u{0431}\u{0440}\u{043E}\u{0448}\u{0435}\u{043D}")
        XCTAssertEqual(controller.state, .idle)
    }

    func testCancelDuringTranscriptionNeverInserts() async throws {
        // Recognition takes a noticeable amount of time - we manage to cancel in the middle.
        // The moment “recognition is underway” is caught by the survey: fixed dream on
        // overloaded CI-runner sleeps longer than the entire recognition.
        let controller = makeController(transcribeDelay: .milliseconds(800))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<400 where controller.state != .transcribing {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.state, .idle)

        let inserted = await inserter.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0430} \u{0432}\u{043E} \u{0432}\u{0440}\u{0435}\u{043C}\u{044F} \u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{044F} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043F}\u{0440}\u{0435}\u{0434}\u{043E}\u{0442}\u{0432}\u{0440}\u{0430}\u{0442}\u{0438}\u{0442}\u{044C} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0443}")
    }

    // MARK: Errors

    func testCaptureFailureSurfacesAndResets() async throws {
        await capture.setStartError(.microphonePermissionDenied)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        XCTAssertEqual(controller.state, .idle)
        let notices = await overlay.notices
        XCTAssertEqual(notices.first?.kind, .failure, "\u{041E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0431}\u{044B}\u{0442}\u{044C} \u{043F}\u{043E}\u{043A}\u{0430}\u{0437}\u{0430}\u{043D}\u{0430}, \u{0430} \u{043D}\u{0435} \u{043F}\u{0440}\u{043E}\u{0433}\u{043B}\u{043E}\u{0447}\u{0435}\u{043D}\u{0430}")
    }

    func testRecognitionFailureIsReported() async throws {
        let controller = makeController(transcribeError: ASREngineError.inferenceFailed("\u{0441}\u{0431}\u{043E}\u{0439}"))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        XCTAssertEqual(notices.first?.kind, .failure)
        XCTAssertEqual(controller.state, .idle)
    }

    func testDependencyCancellationErrorIsAVisibleRecognitionFailureNotUserEscape() async throws {
        var notices: [DictationNotice] = []
        let controller = makeController(transcribeError: CancellationError())
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle(30)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(notices.contains { $0.kind == .failure })
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 1)
    }

    func testEngineCancelledErrorIsAVisibleRecognitionFailureNotUserEscape() async throws {
        var notices: [DictationNotice] = []
        let controller = makeController(transcribeError: ASREngineError.cancelled)
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle(30)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(notices.contains { $0.kind == .failure })
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 1)
    }

    func testTextStaysInMemoryWhenInsertionFails() async throws {
        // Insertion failed - recognized data cannot be lost or written to disk.
        await inserter.setError(.accessibilityPermissionDenied)
        let controller = makeController(recognized: "\u{0432}\u{0430}\u{0436}\u{043D}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}")

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertEqual(controller.pendingRecovery?.text, "\u{0412}\u{0430}\u{0436}\u{043D}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}")
    }

    func testSecureInputFailureExplainsItself() async throws {
        // An active password field is not a product failure, and the message should reflect that.
        await inserter.setError(.secureInputActive)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        XCTAssertTrue(
            notices.contains { $0.message.contains("secure input") },
            "\u{041F}\u{043E}\u{043B}\u{044C}\u{0437}\u{043E}\u{0432}\u{0430}\u{0442}\u{0435}\u{043B}\u{044E} \u{043D}\u{0443}\u{0436}\u{043D}\u{043E} \u{043E}\u{0431}\u{044A}\u{044F}\u{0441}\u{043D}\u{0438}\u{0442}\u{044C}, \u{043F}\u{043E}\u{0447}\u{0435}\u{043C}\u{0443} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{0438}\u{043B}\u{0441}\u{044F}"
        )
    }

    /// ⌘V went out, but no application ever read the clipboard: nothing was
    /// pasted. That is words that did not land, said out loud, with the text
    /// kept for the menu — never a silent success.
    func testAPasteNobodyReadIsReportedAsWordsThatDidNotLand() async throws {
        await inserter.setError(.pasteNotRead)
        let controller = makeController(recognized: "nobody read this")
        var archived: [String] = []
        controller.onTakeFinished = { text, _, _ in
            archived.append(text)
            return true
        }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        let notice = try XCTUnwrap(notices.last)
        XCTAssertEqual(notice.kind, .warning)
        XCTAssertTrue(notice.wordsDidNotLand)
        XCTAssertEqual(notice.recoverableText, "Nobody read this")
        XCTAssertEqual(controller.pendingRecovery?.text, "Nobody read this")
        XCTAssertEqual(archived, ["Nobody read this"])
    }

    /// The person presses the key again while the paste waits for its read:
    /// nothing has appeared, so they are trying again. The press ends the
    /// wait, and the paste nobody read is said out loud now — never a press
    /// that vanishes while they speak into nothing. The next press starts.
    func testAPressWhileThePasteWaitsForItsReadEndsTheWaitOutLoud() async throws {
        let waiting = ReadWaitingInserter()
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in
                ASRResult(text: "nobody read this", audioDuration: 2, processingDuration: 0.1)
            },
            inserter: waiting,
            overlay: overlay,
            sounds: sounds,
            pipeline: { _ in TextPipeline() }
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<400 where !waiting.isWaiting {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.state, .inserting)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        let notices = await overlay.notices
        let notice = try XCTUnwrap(notices.last)
        XCTAssertTrue(notice.wordsDidNotLand)
        XCTAssertEqual(notice.recoverableText, "Nobody read this")
        XCTAssertEqual(controller.pendingRecovery?.text, "Nobody read this")
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 1)
        XCTAssertEqual(controller.state, .idle)
        let startsAfterThePress = await capture.startCount
        XCTAssertEqual(startsAfterThePress, 1, "the press that ended the wait is not a take")

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        let startsAfterTheNextPress = await capture.startCount
        XCTAssertEqual(startsAfterTheNextPress, 2, "the next press starts normally")
    }

    /// The text is already in place, but the insertion holds on to the
    /// restore floor. The person presses again and speaks: that press is
    /// late by at most the floor, never lost.
    func testAPressWhileALandedPasteFinishesStartsItsTake() async throws {
        let landed = LandedPasteInserter()
        let controller = makeController(inserter: landed)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        let pasted = try await waitForPaste(landed, count: 1)
        try await Task.sleep(until: pasted + .milliseconds(100))
        XCTAssertEqual(controller.state, .inserting)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        let deadline = ContinuousClock.now + .seconds(1)
        while await capture.startCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let starts = await capture.startCount
        XCTAssertEqual(starts, 2, "the press starts its take once the paste is done")
        XCTAssertTrue([.preparing, .listening].contains(controller.state), "\(controller.state)")

        controller.stop()
        _ = try await waitForPaste(landed, count: 2)
    }

    /// A press and release inside the hold is the tap it would have been a
    /// moment later: its take starts and stops, and the microphone is never
    /// left on for a key that is already up.
    func testATapWhileALandedPasteFinishesIsStillATap() async throws {
        let landed = LandedPasteInserter()
        let controller = makeController(inserter: landed)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        let pasted = try await waitForPaste(landed, count: 1)
        try await Task.sleep(until: pasted + .milliseconds(100))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        try await Task.sleep(until: pasted + .milliseconds(150))
        controller.stop()
        XCTAssertEqual(controller.state, .inserting)

        _ = try await waitForPaste(landed, count: 2)
        let deadline = ContinuousClock.now + .seconds(1)
        while controller.state != .idle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.state, .idle)
        let starts = await capture.startCount
        let stops = await capture.stopCount
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2, "the tap's take was stopped, not left listening")
    }

    /// A press inside the hold that turns out to be a shortcut (Right ⌘ and
    /// Return, "send" in a chat app) is no take. The hotkey monitor cancels
    /// the hold and swallows its release, so the press that waits for the
    /// paste must go with it, or its take would listen with the key up.
    func testAShortcutPressedWhileALandedPasteFinishesStartsNothing() async throws {
        let landed = LandedPasteInserter()
        let controller = makeController(inserter: landed)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        let pasted = try await waitForPaste(landed, count: 1)
        try await Task.sleep(until: pasted + .milliseconds(80))
        XCTAssertEqual(controller.state, .inserting)
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        // What `onAbortShortcut` does; the release that follows never comes.
        controller.cancel()

        try await Task.sleep(until: pasted + .milliseconds(600))
        XCTAssertEqual(controller.state, .idle)
        let starts = await capture.startCount
        XCTAssertEqual(starts, 1, "the shortcut started no take")
    }

    /// Nothing was pasted, and putting the person's clipboard back failed
    /// too. Both are said: the text is in the menu, and what they had copied
    /// is gone.
    func testAFailedPasteThatAlsoLostTheClipboardSaysSo() async throws {
        await inserter.setError(.clipboardRestoreFailed)
        let controller = makeController(recognized: "lost both")

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        let notice = try XCTUnwrap(notices.last)
        XCTAssertEqual(notice.kind, .warning)
        XCTAssertTrue(notice.wordsDidNotLand)
        XCTAssertEqual(notice.recoverableText, "Lost both")
        XCTAssertEqual(
            notice.message,
            L10n.tr("The text couldn't be inserted, and the previous clipboard couldn't be restored. The text is saved in the menu.")
        )
    }

    private func waitForPaste(
        _ inserter: LandedPasteInserter,
        count: Int
    ) async throws -> ContinuousClock.Instant {
        let deadline = ContinuousClock.now + .seconds(2)
        while inserter.pasteCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(inserter.pasteCount, count)
        return try XCTUnwrap(inserter.lastPaste)
    }

    // MARK: Insertion target

    func testTargetUsesPrepopulatedSnapshotWithoutAKeyDownSystemQuery() async throws {
        let cached = TargetApplication(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 1,
            localizedName: "TextEdit"
        )
        inserter.frontmost = TargetApplication(
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 2,
            localizedName: "Safari"
        )
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in
                ASRResult(text: "cached target", audioDuration: 1, processingDuration: 0.01)
            },
            inserter: inserter,
            targetApplicationSnapshot: { cached },
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let targets = await inserter.targets
        XCTAssertEqual(targets.first ?? nil, cached)
    }

    func testTargetIsCapturedAtKeyDownNotAtInsertion() async throws {
        let original = TargetApplication(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 1, localizedName: "TextEdit")
        inserter.frontmost = original

        let controller = makeController(transcribeDelay: .milliseconds(60))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        // While recognition is in progress, the user has switched to another application.
        inserter.frontmost = TargetApplication(bundleIdentifier: "com.apple.Safari", processIdentifier: 2, localizedName: "Safari")
        controller.stop()
        await settle(30)

        let targets = await inserter.targets
        XCTAssertEqual(
            targets.first??.bundleIdentifier,
            "com.apple.TextEdit",
            "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043F}\u{043E}\u{043F}\u{0430}\u{0441}\u{0442}\u{044C} \u{0442}\u{0443}\u{0434}\u{0430}, \u{0433}\u{0434}\u{0435} \u{0435}\u{0433}\u{043E} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{0430}\u{043B}\u{0438}"
        )
    }

    // MARK: Command at the end of the phrase

    func testSafeBetaNeverPressesReturnFromSpeech() async throws {
        let controller = makeController(recognized: "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        let presses = await inserter.returnPresses
        XCTAssertEqual(inserted, ["\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}"])
        XCTAssertEqual(presses, 0, "False trigger \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{043B}\u{044F}\u{0442}\u{044C} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435}")
    }

    func testNewLineCommandArrivesAsTextNotAsKeypress() async throws {
        // The “new line” must reach the input field by wrapping. Press Return
        // not allowed here: it will send a message in the messenger.
        let controller = makeController(recognized: "\u{043F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430} \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        let presses = await inserter.returnPresses
        XCTAssertEqual(inserted, ["\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}\n"])
        XCTAssertEqual(presses, 0, "Return \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{043B} \u{0431}\u{044B} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435} \u{0432}\u{043C}\u{0435}\u{0441}\u{0442}\u{043E} \u{043F}\u{0435}\u{0440}\u{0435}\u{043D}\u{043E}\u{0441}\u{0430} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}")
    }

    // MARK: Empty result

    func testEmptyRecognitionInsertsNothingAndDoesNotError() async throws {
        // Previously, "no messages" were checked here. The requirement was
        // formulated as “remaining silent is not a mistake”, and this is true: a mistake
        // empty result is not. But silence turned out to be the wrong answer:
        // a darkened panel without text is indistinguishable from “inserted into someone else’s window”,
        // and the person went to look for a phrase where it did not exist. Let's check what
        // required: no error, nothing inserted, vote not saved.
        let controller = makeController(recognized: "   ")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertTrue(
            notices.allSatisfy { $0.kind != .failure },
            "\u{041F}\u{0443}\u{0441}\u{0442}\u{043E}\u{0439} \u{0440}\u{0435}\u{0437}\u{0443}\u{043B}\u{044C}\u{0442}\u{0430}\u{0442} — \u{043D}\u{0435} \u{0441}\u{0431}\u{043E}\u{0439}: \(notices.map(\.message))"
        )
        XCTAssertTrue(notices.allSatisfy { $0.recoveryAudio == nil })
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Microphone and cleaning

    func testOverlayIsDismissedOnEveryPath() async throws {
        // Successful path.
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()
        let afterSuccess = await overlay.dismissCount
        XCTAssertGreaterThan(afterSuccess, 0)

        // Path with cancellation.
        let cancelled = makeController()
        cancelled.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        cancelled.cancel()
        await settle()
        let afterCancel = await overlay.dismissCount
        XCTAssertGreaterThan(afterCancel, afterSuccess, "\u{0418}\u{043D}\u{0434}\u{0438}\u{043A}\u{0430}\u{0442}\u{043E}\u{0440} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0443}\u{0431}\u{0438}\u{0440}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0438} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B}")
    }

    func testDisabledOrMissingModelPreventsStart() async throws {
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: false, isModelReady: true)
        await settle(3)
        controller.begin(handsFree: false, isEnabled: true, isModelReady: false)
        await settle(3)

        let starts = await capture.startCount
        XCTAssertEqual(starts, 0, "\u{0411}\u{0435}\u{0437} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438} \u{0438}\u{043B}\u{0438} \u{043F}\u{0440}\u{0438} \u{0432}\u{044B}\u{043A}\u{043B}\u{044E}\u{0447}\u{0435}\u{043D}\u{043D}\u{043E}\u{0439} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0435} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043D}\u{0435} \u{043D}\u{0430}\u{0447}\u{0438}\u{043D}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F}")
    }

    // MARK: Hands-free mode

    func testHandsFreeIgnoresKeyRelease() async throws {
        let controller = makeController()
        controller.begin(handsFree: true, isEnabled: true, isModelReady: true)
        await settle()

        // In hands-free mode, releasing the key does nothing.
        controller.stop()
        await settle(4)
        XCTAssertEqual(controller.state, .listening, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043F}\u{0440}\u{043E}\u{0434}\u{043E}\u{043B}\u{0436}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F}")

        controller.stopHandsFree()
        await settle()
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1)
    }
}
