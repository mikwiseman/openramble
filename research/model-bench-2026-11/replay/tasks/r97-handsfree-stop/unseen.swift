import XCTest
@testable import DictationCore

// Presses no model was shown, for the task r97-handsfree-stop.
//
// The grader copies this file into the test target of a change that passed
// the tests. It leans on the test doubles of the real change's race tests,
// which the grader has put in place by then: Gate, TrackedCapture,
// RecordingInserter, QuietOverlay, CountingSounds, TranscribeTracker and
// SeededGenerator.
//
// It checks what the real change's storm checks, the microphone off and the
// next dictation working, in two places the storm of the tests does not reach:
// every short run of presses that falls inside one finishing paste, placed
// there on purpose and not by timing, and storms with seeds nobody ran.

/// A paste that lands and then holds, as the real one holds its clipboard
/// restore floor, until the test lets it finish.
actor UnseenHeldInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private let gate: Gate

    init(gate: Gate) { self.gate = gate }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        insertedTexts.append(text)
        await gate.pass()
    }
    func pressReturn() async throws {}
    nonisolated func frontmostApplication() -> TargetApplication? { nil }
}

@MainActor
final class BenchUnseenTests: XCTestCase {
    enum Gesture: String, CaseIterable {
        case hold, handsFree, release, cancel, interrupt, promote, secondPress
    }

    private func make(_ gesture: Gesture, on controller: DictationController) {
        switch gesture {
        case .hold: controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        case .handsFree: controller.begin(handsFree: true, isEnabled: true, isModelReady: true)
        case .release: controller.stop()
        case .cancel: controller.cancel()
        case .interrupt: controller.interrupt(reason: "disk full")
        case .promote: controller.promoteToHandsFree()
        case .secondPress: controller.stopHandsFree()
        }
    }

    private func makeController(
        capture: TrackedCapture, inserter: any TextInserting, transcribes: TranscribeTracker
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in
                await transcribes.enter()
                defer { Task { await transcribes.leave() } }
                return ASRResult(text: "hello world", audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: QuietOverlay(),
            sounds: CountingSounds()
        )
    }

    private func settle(_ iterations: Int) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Wait until every tail has settled, as the real change's tests do.
    private func quiesce(
        _ controller: DictationController, _ capture: TrackedCapture, _ transcribes: TranscribeTracker
    ) async {
        for _ in 0..<400 {
            let captureIdle = await capture.inFlight == 0
            let transcribeIdle = await transcribes.inFlight == 0
            if controller.state == .idle, captureIdle, transcribeIdle { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        await settle(4)
    }

    private func reached(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if await condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    /// What is wrong once the hand has left the key, or nil. The checks are
    /// the ones of the real change's storm. `takes`, where given, is how many
    /// takes must have started and landed by then.
    private func broken(
        _ controller: DictationController, _ capture: TrackedCapture, _ transcribes: TranscribeTracker,
        takes: Int? = nil, inserted: () async -> Int
    ) async -> String? {
        await quiesce(controller, capture, transcribes)
        if controller.state != .idle { return "the session hangs" }
        if await capture.isRecording { return "the microphone stays on" }
        let before = await inserted()
        let starts = await capture.startCount
        if before > starts { return "a text was inserted twice" }
        if let takes, starts != takes || before != takes {
            return "the press was lost: \(starts) takes started and \(before) landed, where \(takes) should"
        }
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(6)
        controller.stop()
        await quiesce(controller, capture, transcribes)
        if await inserted() != before + 1 { return "the next dictation inserts nothing" }
        return nil
    }

    // MARK: - Inside one finishing paste

    private func pasteCase(_ gestures: [Gesture]) async -> String? {
        let capture = TrackedCapture()
        let transcribes = TranscribeTracker()
        let gate = Gate()
        let inserter = UnseenHeldInserter(gate: gate)
        let controller = makeController(capture: capture, inserter: inserter, transcribes: transcribes)

        // One ordinary take, up to the moment its text is in place.
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        guard await reached({ controller.state == .listening }) else { return "setup: it never listened" }
        controller.stop()
        guard await reached({ controller.state == .inserting }),
              await reached({ await inserter.insertedTexts.count == 1 })
        else { return "setup: the first paste never landed" }

        // Everything from here to the gate arrives while that paste finishes.
        for gesture in gestures { make(gesture, on: controller) }
        // The hand leaves the key, as at the end of the real change's storm.
        controller.stop()
        controller.stopHandsFree()
        await gate.open()

        // One press with its own stop is a take of its own, as it would have
        // been a moment later.
        let takes: Int? = gestures == [.hold] || gestures == [.handsFree] ? 2 : nil
        return await broken(controller, capture, transcribes, takes: takes) { await inserter.insertedTexts.count }
    }

    func testPressesInsideAFinishingPaste() async throws {
        var sequences: [[Gesture]] = [[]]
        for first in Gesture.allCases {
            sequences.append([first])
            for second in Gesture.allCases {
                sequences.append([first, second])
                for third in Gesture.allCases { sequences.append([first, second, third]) }
            }
        }
        var failed = 0
        for gestures in sequences {
            if let what = await pasteCase(gestures) {
                failed += 1
                print("UNSEEN-FAIL paste [\(gestures.map(\.rawValue).joined(separator: ", "))]: \(what)")
            }
        }
        print("UNSEEN paste \(failed) of \(sequences.count)")
        XCTAssertEqual(failed, 0)
    }

    // MARK: - Storms with seeds nobody ran

    private func storm(seed: Int, length: Int) async -> String? {
        let capture = TrackedCapture()
        let transcribes = TranscribeTracker()
        let inserter = RecordingInserter(hold: .milliseconds(20))
        let controller = makeController(capture: capture, inserter: inserter, transcribes: transcribes)
        var rng = SeededGenerator(seed: UInt64(seed))

        for _ in 0..<length {
            switch Int(rng.next() % 7) {
            case 0: make(.hold, on: controller)
            case 1: make(.handsFree, on: controller)
            case 2: make(.release, on: controller)
            case 3: make(.cancel, on: controller)
            case 4: make(.interrupt, on: controller)
            case 5: make(.promote, on: controller)
            default: make(.secondPress, on: controller)
            }
            let pause = Int(rng.next() % 4)
            if pause > 0 { try? await Task.sleep(for: .milliseconds(pause)) } else { await Task.yield() }
        }
        controller.stop()
        controller.stopHandsFree()
        return await broken(controller, capture, transcribes) { await inserter.insertedTexts.count }
    }

    func testStormsWithSeedsNobodyRan() async throws {
        // The real change's test runs seeds 0 to 199 with 6 gestures each.
        var failed = 0
        var total = 0
        for (seeds, length) in [(200..<400, 6), (400..<500, 10)] {
            for seed in seeds {
                total += 1
                if let what = await storm(seed: seed, length: length) {
                    failed += 1
                    print("UNSEEN-FAIL storm [seed \(seed), \(length) gestures]: \(what)")
                }
            }
        }
        print("UNSEEN storm \(failed) of \(total)")
        XCTAssertEqual(failed, 0)
    }
}
