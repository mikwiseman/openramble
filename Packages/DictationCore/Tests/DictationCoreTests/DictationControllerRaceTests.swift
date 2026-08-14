import XCTest
@testable import DictationCore

// MARK: - Edges that can be controlled by beats

/// Gate: holds the challenge until the test opens it.
///
/// Cancel in Swift does not interrupt an already started wait - it only marks it.
/// The gate reproduces this honestly: the continuation wakes up when it decides
/// test, not when cancel worked. It is into this gap that they fall
/// tails of canceled sessions.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// A microphone that shows whether it is turned on right now.
///
/// Behaves like a real engine: it doesn’t start a second record on top of the current one, but
/// refuses. Without this, the test would not distinguish “microphone muted” from “microphone
/// forgotten when turned on,” and this is the main promise of the product.
actor TrackedCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var isRecording = false
    private(set) var inFlight = 0

    private var startGate: Gate?
    private var abortGate: Gate?
    private let file = URL(fileURLWithPath: "/tmp/tracked-take.wav")

    func setStartGate(_ gate: Gate?) { startGate = gate }
    func setAbortGate(_ gate: Gate?) { abortGate = gate }

    func startRecording() async throws -> URL {
        startCount += 1
        inFlight += 1
        defer { inFlight -= 1 }
        if let startGate { await startGate.pass() }
        guard !isRecording else { throw AudioCaptureError.engineUnavailable("\u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0443}\u{0436}\u{0435} \u{0438}\u{0434}\u{0451}\u{0442}") }
        isRecording = true
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        inFlight += 1
        defer { inFlight -= 1 }
        guard isRecording else { throw AudioCaptureError.notRecording }
        isRecording = false
        return (file, 2.0)
    }

    func abortRecording() async {
        if let abortGate { await abortGate.pass() }
        isRecording = false
    }
}

/// A cancellation-deaf microphone start whose eventual ownership action is
/// observable. It distinguishes user Escape (delete) from a technical timeout
/// (contain and preserve) after the same late `.started` result.
actor LateStartDispositionCapture: AudioCapturing {
    private let startGate: Gate
    private let file = URL(fileURLWithPath: "/tmp/late-start-disposition.wav")
    private(set) var isRecording = false
    private(set) var abortCount = 0
    private(set) var containCount = 0

    init(startGate: Gate) { self.startGate = startGate }

    func startRecording() async throws -> URL {
        await startGate.pass()
        isRecording = true
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        isRecording = false
        return (file, 2)
    }

    func abortRecording() async {
        abortCount += 1
        isRecording = false
    }

    func abortRecording(session: DictationSessionID, expectedURL: URL?) async {
        abortCount += 1
        isRecording = false
    }

    func containRecording(session: DictationSessionID, expectedURL: URL?) async {
        containCount += 1
        isRecording = false
    }
}

private final class CancellationResponsiveBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.open()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// Models the exact production handoff: the active engine is detached before
/// waiting for the last PCM callback, and cancellation releases that barrier.
actor DetachedFreezeCapture: AudioCapturing {
    private let directory: URL
    private let firstFreeze = CancellationResponsiveBarrier()
    private var activeURL: URL?
    private(set) var freezeCount = 0

    init(directory: URL) {
        self.directory = directory
    }

    func startRecording() async throws -> URL {
        guard activeURL == nil else {
            throw AudioCaptureError.engineUnavailable("recording already active")
        }
        let url = directory.appending(path: "take-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: 128))
        activeURL = url
        return url
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        let recording = try await freezeRecording()
        return (try await recording.durableURL(), recording.duration)
    }

    func freezeRecording() async throws -> CapturedRecording {
        guard let url = activeURL else { throw AudioCaptureError.notRecording }
        activeURL = nil
        freezeCount += 1
        if freezeCount == 1 {
            await firstFreeze.wait()
            try Task.checkCancellation()
        }
        return CapturedRecording(url: url, duration: 2, samples: [0.1, 0.2])
    }

    func abortRecording() async {
        await abortRecording(expectedURL: nil)
    }

    func abortRecording(expectedURL: URL?) async {
        if let expectedURL, activeURL != expectedURL {
            try? FileManager.default.removeItem(at: expectedURL)
            return
        }
        if let activeURL { try? FileManager.default.removeItem(at: activeURL) }
        activeURL = nil
    }

    var currentURL: URL? { activeURL }
}

actor RecordingInserter: TextInserting {
    private(set) var insertedTexts: [String] = []

    func insert(_ text: String, into target: TargetApplication?) async throws {
        insertedTexts.append(text)
    }
    func pressReturn() async throws {}
    nonisolated func frontmostApplication() -> TargetApplication? { nil }
}

actor QuietOverlay: OverlayPresenting {
    func present(_ state: DictationState, elapsed: TimeInterval) async {}
    func dismiss() async {}
    func presentNotice(_ notice: DictationNotice) async {}
}

actor CountingSounds: Sounding {
    private(set) var attentionPlays = 0
    func playAttention() async { attentionPlays += 1 }
}

/// Counter of recognition calls, accessible from the `@Sendable` closure.
actor TranscribeTracker {
    private(set) var inFlight = 0
    private(set) var count = 0
    func enter() { count += 1; inFlight += 1 }
    func leave() { inFlight -= 1 }
}

/// Reproducible generator: the failed run should be repeated by number.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Race tests

/// Races between user gestures and the tails of already canceled sessions.
///
/// Everything that is checked here cannot be caught by reading: cancel marks
/// waits, but does not interrupt it, and the continuation wakes up in someone else's session.
@MainActor
final class DictationControllerRaceTests: XCTestCase {
    private var capture: TrackedCapture!
    private var inserter: RecordingInserter!
    private var overlay: QuietOverlay!
    private var sounds: CountingSounds!
    private var transcribes: TranscribeTracker!

    override func setUp() async throws {
        capture = TrackedCapture()
        inserter = RecordingInserter()
        overlay = QuietOverlay()
        sounds = CountingSounds()
        transcribes = TranscribeTracker()
    }

    private func makeController(
        recognized: String = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}",
        transcribeGate: Gate? = nil
    ) -> DictationController {
        let tracker = transcribes!
        return DictationController(
            capture: capture,
            transcribe: { _ in
                await tracker.enter()
                defer { Task { await tracker.leave() } }
                if let transcribeGate { await transcribeGate.pass() }
                return ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )
    }

    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Wait until all the tails settle down: both the state and the edges of the system.
    private func quiesce(_ controller: DictationController, limit: Int = 400) async {
        for _ in 0..<limit {
            let captureIdle = await capture.inFlight == 0
            let transcribeIdle = await transcribes.inFlight == 0
            if controller.state == .idle, captureIdle, transcribeIdle { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        await settle(4)
    }

    // MARK: - Tail of the canceled session

    func testStaleFinalizationDoesNotTearDownTheNextSession() async throws {
        // Recognition hangs in the gate. Cancellation marks him, but does not wake him up -
        // exactly like a real recognition that finishes reading its buffer.
        let gate = Gate()
        let controller = makeController(transcribeGate: gate)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        await settle()
        XCTAssertEqual(controller.state, .idle, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{0442}\u{044C} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{044E} \u{0441}\u{0440}\u{0430}\u{0437}\u{0443}")

        // The person does not wait: he immediately dictates again.
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        // The tail of the canceled session now wakes up.
        await gate.open()
        await settle(20)

        XCTAssertEqual(
            controller.state,
            .listening,
            "\u{0425}\u{0432}\u{043E}\u{0441}\u{0442} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{043E}\u{0439} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{0438} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{0433}\u{0430}\u{0441}\u{0438}\u{0442}\u{044C} \u{043D}\u{043E}\u{0432}\u{0443}\u{044E}"
        )
        let stillRecording = await capture.isRecording
        XCTAssertTrue(stillRecording, "\u{041C}\u{0438}\u{043A}\u{0440}\u{043E}\u{0444}\u{043E}\u{043D} \u{043D}\u{043E}\u{0432}\u{043E}\u{0439} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{0438} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0451}\u{043D}\u{043D}\u{044B}\u{043C}")

        // And the new session must normally reach the insertion.
        controller.stop()
        await quiesce(controller)
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"], "\u{0412}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043F}\u{0440}\u{043E}\u{043F}\u{0430}\u{0441}\u{0442}\u{044C}")
    }

    func testCancelReturnsControllerToIdleWithoutAwaitingWedgedAbort() async throws {
        let gate = Gate()
        await capture.setAbortGate(gate)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)
        controller.cancel()

        for _ in 0..<100 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(controller.state, .idle, "a cancellation-deaf device edge cannot own UI liveness")

        await gate.open()
        await quiesce(controller)
    }

    func testCanceledPreparingWatchdogCannotDisableTheNextSessionWatchdog() async throws {
        let startGate = Gate()
        await capture.setStartGate(startGate)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "ok", audioDuration: 2, processingDuration: 0) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            captureFreezeDeadline: .milliseconds(30)
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(2)
        controller.stop()
        controller.cancel()
        await settle(5)
        XCTAssertEqual(controller.state, .idle)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(2)
        controller.stop()
        for _ in 0..<150 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(controller.state, .idle, "N+1 must own a fresh absolute-start watchdog")

        await startGate.open()
        await settle(20)
        controller.cancel()
    }

    func testLateStartAfterTechnicalWatchdogIsContainedWithoutUserDeletion() async throws {
        let startGate = Gate()
        let lateCapture = LateStartDispositionCapture(startGate: startGate)
        let controller = DictationController(
            capture: lateCapture,
            transcribe: { _ in ASRResult(text: "must not run", audioDuration: 2, processingDuration: 0) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            captureFreezeDeadline: .milliseconds(30)
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(2)
        controller.stop()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(controller.state, .idle)

        await startGate.open()
        await settle(20)

        let abortCount = await lateCapture.abortCount
        let containCount = await lateCapture.containCount
        let recording = await lateCapture.isRecording
        XCTAssertEqual(abortCount, 0)
        XCTAssertGreaterThanOrEqual(containCount, 1)
        XCTAssertFalse(recording)
    }

    func testLateStartAfterEscapeUsesDestructiveAbort() async throws {
        let startGate = Gate()
        let lateCapture = LateStartDispositionCapture(startGate: startGate)
        let controller = DictationController(
            capture: lateCapture,
            transcribe: { _ in ASRResult(text: "must not run", audioDuration: 2, processingDuration: 0) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(2)
        controller.cancel()
        await settle(5)
        XCTAssertEqual(controller.state, .idle)

        await startGate.open()
        await settle(20)

        let abortCount = await lateCapture.abortCount
        let containCount = await lateCapture.containCount
        let recording = await lateCapture.isRecording
        XCTAssertGreaterThanOrEqual(abortCount, 1)
        XCTAssertEqual(containCount, 0)
        XCTAssertFalse(recording)
    }

    func testHandsFreeCallbackCanStopReentrantlyWithoutLosingTheStop() async throws {
        let controller = makeController()
        controller.onHandsFreeChange = { active in
            if active { controller.stopHandsFree() }
        }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.promoteToHandsFree()
        await quiesce(controller)

        XCTAssertEqual(controller.state, .idle)
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1)
    }

    func testIdleObserverCanStartNextSessionWithoutOldCleanupOrphaningIt() async throws {
        let controller = makeController()
        var restarted = false
        controller.onStateChange = { state in
            guard state == .idle, !restarted else { return }
            restarted = true
            controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<300 where controller.state != .listening || !restarted {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertTrue(restarted)
        XCTAssertEqual(controller.state, .listening)
        let recording = await capture.isRecording
        XCTAssertTrue(recording)

        controller.stop()
        await quiesce(controller)
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 2)
    }

    func testStaleStartDoesNotAdoptTheNextSession() async throws {
        // The record rises slowly: they have time to release and cancel earlier.
        let gate = Gate()
        await capture.setStartGate(gate)
        let controller = makeController()
        var failures = 0
        controller.onNotice = { if $0.kind == .failure { failures += 1 } }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(3)
        controller.cancel()
        await settle(3)
        XCTAssertEqual(controller.state, .idle)

        // The second session begins while the first one is still hanging in the engine startup.
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(3)

        await gate.open()
        await quiesce(controller)

        // Two outcomes are legitimate here: the stale start aborts in time and
        // the second session records, or the capture honestly refuses the
        // overlapping start and the second session fails with a notice. The
        // sound must follow the notice exactly — never fire without one.
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, failures, "the attention sound plays if and only if a failure was surfaced")

        // The main thing: after everything has calmed down, the microphone must be turned off.
        controller.cancel()
        await quiesce(controller)
        let recording = await capture.isRecording
        XCTAssertFalse(recording, "\u{041C}\u{0438}\u{043A}\u{0440}\u{043E}\u{0444}\u{043E}\u{043D} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0451}\u{043D}\u{043D}\u{044B}\u{043C} \u{043E}\u{0442} \u{0431}\u{0440}\u{043E}\u{0448}\u{0435}\u{043D}\u{043D}\u{043E}\u{0433}\u{043E} \u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{043A}\u{0430}")
    }

    func testFreezeTimeoutAndStaleAbortCannotStopTheNextSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "detached-freeze-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let detached = DetachedFreezeCapture(directory: directory)
        let controller = DictationController(
            capture: detached,
            transcribe: { _ in ASRResult(text: "new session", audioDuration: 2, processingDuration: 0) },
            transcribeSamples: { _ in ASRResult(text: "new session", audioDuration: 2, processingDuration: 0) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            captureFreezeDeadline: .milliseconds(30)
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        let oldCurrentURL = await detached.currentURL
        let oldURL = try XCTUnwrap(oldCurrentURL)
        controller.stop()
        for _ in 0..<300 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        let newCurrentURL = await detached.currentURL
        let newURL = try XCTUnwrap(newCurrentURL)
        XCTAssertNotEqual(newURL, oldURL)

        // This is the late cleanup that used to call the unscoped abort and
        // turn off whichever engine happened to be current.
        await detached.abortRecording(expectedURL: oldURL)
        let activeAfterStaleAbort = await detached.currentURL
        XCTAssertEqual(activeAfterStaleAbort, newURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))

        controller.stop()
        for _ in 0..<300 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .idle)
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["New session"])
    }

    func testCancelWhileFreezingIsSilentAndRemovesOnlyThatTake() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cancel-during-freeze-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let detached = DetachedFreezeCapture(directory: directory)
        let controller = DictationController(
            capture: detached,
            transcribe: { _ in ASRResult(text: "must not run", audioDuration: 2, processingDuration: 0) },
            transcribeSamples: { _ in ASRResult(text: "must not run", audioDuration: 2, processingDuration: 0) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            captureFreezeDeadline: .seconds(5)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        let currentURL = await detached.currentURL
        let takeURL = try XCTUnwrap(currentURL)
        controller.stop()
        await settle(2)
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        for _ in 0..<300 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }

        let attentionPlays = await sounds.attentionPlays
        let insertedTexts = await inserter.insertedTexts
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(notices.isEmpty, "Escape during capture freeze must not become an error")
        XCTAssertEqual(attentionPlays, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: takeURL.path))
        XCTAssertTrue(insertedTexts.isEmpty)
    }

    // MARK: - Storm of gestures

    func testRandomGestureStormsAlwaysLeaveTheMicrophoneOff() async throws {
        // Hundreds of random rotations. It is not the “correct” outcome that is being checked
        // each - there are too many of them - and two promises that must
        // always hold on: the microphone is turned off and the next dictation works.
        for seed in 0..<200 {
            capture = TrackedCapture()
            inserter = RecordingInserter()
            overlay = QuietOverlay()
            sounds = CountingSounds()
            transcribes = TranscribeTracker()

            let controller = makeController()
            var rng = SeededGenerator(seed: UInt64(seed))

            for _ in 0..<6 {
                switch Int(rng.next() % 7) {
                case 0: controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
                case 1: controller.begin(handsFree: true, isEnabled: true, isModelReady: true)
                case 2: controller.stop()
                case 3: controller.cancel()
                case 4: controller.interrupt(reason: "\u{0434}\u{0438}\u{0441}\u{043A} \u{0437}\u{0430}\u{043F}\u{043E}\u{043B}\u{043D}\u{0435}\u{043D}")
                case 5: controller.promoteToHandsFree()
                default: controller.stopHandsFree()
                }
                let pause = Int(rng.next() % 4)
                if pause > 0 { try? await Task.sleep(for: .milliseconds(pause)) }
                else { await Task.yield() }
            }

            // The key is always released at the end of the storm: the hand does not remain on the button.
            controller.stop()
            controller.stopHandsFree()
            await quiesce(controller)

            XCTAssertEqual(controller.state, .idle, "\u{0421}\u{0435}\u{0441}\u{0441}\u{0438}\u{044F} \u{0437}\u{0430}\u{0432}\u{0438}\u{0441}\u{043B}\u{0430}, seed \(seed)")
            let recording = await capture.isRecording
            XCTAssertFalse(recording, "\u{041C}\u{0438}\u{043A}\u{0440}\u{043E}\u{0444}\u{043E}\u{043D} \u{043E}\u{0441}\u{0442}\u{0430}\u{043B}\u{0441}\u{044F} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0451}\u{043D}\u{043D}\u{044B}\u{043C}, seed \(seed)")

            let insertedBefore = await inserter.insertedTexts.count
            let startsBefore = await capture.startCount
            XCTAssertLessThanOrEqual(
                insertedBefore,
                startsBefore,
                "\u{0412}\u{0441}\u{0442}\u{0430}\u{0432}\u{043E}\u{043A} \u{0431}\u{043E}\u{043B}\u{044C}\u{0448}\u{0435}, \u{0447}\u{0435}\u{043C} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0435}\u{0439} — \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{0437}\u{0430}\u{0434}\u{0432}\u{043E}\u{0438}\u{043B}\u{0441}\u{044F}, seed \(seed)"
            )

            // There must be a way out of any storm: regular dictation works.
            controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
            await settle(6)
            controller.stop()
            await quiesce(controller)

            let insertedAfter = await inserter.insertedTexts.count
            XCTAssertEqual(
                insertedAfter,
                insertedBefore + 1,
                "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0448}\u{0442}\u{043E}\u{0440}\u{043C}\u{0430} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{0441}\u{043D}\u{043E}\u{0432}\u{0430} \u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430}\u{0442}\u{044C}, seed \(seed)"
            )
        }
    }
}
