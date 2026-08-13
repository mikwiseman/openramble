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
    private let file = URL(fileURLWithPath: "/tmp/tracked-take.wav")

    func setStartGate(_ gate: Gate?) { startGate = gate }

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

    func abortRecording() async { isRecording = false }
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

    func testStaleStartDoesNotAdoptTheNextSession() async throws {
        // The record rises slowly: they have time to release and cancel earlier.
        let gate = Gate()
        await capture.setStartGate(gate)
        let controller = makeController()

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

        let plays = await sounds.attentionPlays
        XCTAssertLessThanOrEqual(plays, 1, "\u{041E}\u{0434}\u{0438}\u{043D} \u{0436}\u{0438}\u{0432}\u{043E}\u{0439} \u{0441}\u{0435}\u{0430}\u{043D}\u{0441} — \u{043E}\u{0434}\u{0438}\u{043D} \u{0437}\u{0432}\u{0443}\u{043A} \u{043D}\u{0430}\u{0447}\u{0430}\u{043B}\u{0430} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438}")

        // The main thing: after everything has calmed down, the microphone must be turned off.
        controller.cancel()
        await quiesce(controller)
        let recording = await capture.isRecording
        XCTAssertFalse(recording, "\u{041C}\u{0438}\u{043A}\u{0440}\u{043E}\u{0444}\u{043E}\u{043D} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0451}\u{043D}\u{043D}\u{044B}\u{043C} \u{043E}\u{0442} \u{0431}\u{0440}\u{043E}\u{0448}\u{0435}\u{043D}\u{043D}\u{043E}\u{0433}\u{043E} \u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{043A}\u{0430}")
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
