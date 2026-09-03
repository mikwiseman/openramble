import XCTest
@testable import DictationCore

/// Echo is a delayed copy; the person is not. Decisions are made over a
/// window, held for a while, and never lose the person's first words.
final class CrossTalkGateTests: XCTestCase {
    /// Deterministic "speech": a fixed pseudo-random sequence.
    private func noise(_ count: Int, seed: UInt64, amplitude: Float) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    private func delayed(_ samples: [Float], by frames: Int, gain: Float) -> [Float] {
        (0..<samples.count).map { $0 < frames ? 0 : samples[$0 - frames] * gain }
    }

    private func mixed(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map(+)
    }

    func testTheSpeakersLeakingIntoTheMicrophoneIsAnEchoAtTheRightLag() {
        var gate = CrossTalkGate()
        let system = noise(5_120, seed: 1, amplitude: 0.2)
        // Half the level, 30 ms later, over a little room noise.
        let microphone = mixed(delayed(system, by: 480, gain: 0.5), noise(5_120, seed: 2, amplitude: 0.01))
        let verdict = gate.classify(microphone: microphone, system: system)
        XCTAssertTrue(verdict.isEcho)
        XCTAssertEqual(verdict.lagFrames ?? -1, 480, accuracy: 32)
        XCTAssertGreaterThan(verdict.correlation, 0.9)
    }

    func testAnEchoOfTheEndOfThePreviousBlockIsStillCaught() {
        var gate = CrossTalkGate()
        let first = noise(5_120, seed: 3, amplitude: 0.2)
        let second = noise(5_120, seed: 4, amplitude: 0.2)
        let whole = first + second
        // The microphone hears everything 40 ms late: the start of this block's
        // echo is the end of the previous block's audio.
        let echo = delayed(whole, by: 640, gain: 0.5)
        _ = gate.classify(microphone: Array(echo[0..<5_120]), system: first)
        let verdict = gate.classify(microphone: Array(echo[5_120...]), system: second)
        XCTAssertTrue(verdict.isEcho)
        XCTAssertEqual(verdict.lagFrames ?? -1, 640, accuracy: 32)
    }

    /// Sources deliver a few milliseconds at a time. Every one of those
    /// blocks must come out as echo, or the segmenter makes a paragraph of it.
    func testEveryTinyBlockOfAnEchoIsAnEcho() {
        var gate = CrossTalkGate()
        let system = noise(48_000, seed: 5, amplitude: 0.2)
        let echo = delayed(system, by: 480, gain: 0.5)
        var verdicts: [Bool] = []
        var start = 0
        while start < system.count {
            let end = min(start + 170, system.count)
            verdicts.append(gate.classify(microphone: Array(echo[start..<end]), system: Array(system[start..<end])).isEcho)
            start = end
        }
        XCTAssertEqual(verdicts.count, 283)
        XCTAssertTrue(verdicts.allSatisfy { $0 }, "\(verdicts.filter { !$0 }.count) blocks slipped through")
    }

    /// Before there is enough context to decide, an active system side is
    /// taken as echo and a quiet one is not.
    func testBeforeEnoughContextAnActiveSystemSideIsTakenAsEcho() {
        var gate = CrossTalkGate()
        let system = noise(512, seed: 6, amplitude: 0.2)
        XCTAssertTrue(gate.classify(microphone: noise(512, seed: 7, amplitude: 0.1), system: system).isEcho)
        gate.reset()
        XCTAssertFalse(gate.classify(microphone: noise(512, seed: 7, amplitude: 0.1), system: noise(512, seed: 8, amplitude: 0.001)).isEcho)
    }

    /// The other side stops; the room keeps ringing for a moment and the
    /// microphone still clears the speech floor. The decision holds through
    /// it — the window remembers the source for 320 ms and the hold adds
    /// 300 — then lets go.
    func testADecisionOutlastsItsEvidenceForAboutSixHundredMilliseconds() {
        var gate = CrossTalkGate()
        let system = noise(5_120, seed: 9, amplitude: 0.2)
        XCTAssertTrue(gate.classify(microphone: delayed(system, by: 480, gain: 0.5), system: system).isEcho)
        var verdicts: [Bool] = []
        for block in 0..<8 {
            let quiet = noise(1_600, seed: 100 + UInt64(block), amplitude: 0.001)
            let tail = noise(1_600, seed: 200 + UInt64(block), amplitude: 0.03)
            verdicts.append(gate.classify(microphone: tail, system: quiet).isEcho)
        }
        XCTAssertEqual(verdicts, [true, true, true, true, true, false, false, false])
    }

    func testThePersonSpeakingIsNotAnEchoWhateverTheLevels() {
        var gate = CrossTalkGate()
        let system = noise(5_120, seed: 10, amplitude: 0.2)
        let person = noise(5_120, seed: 11, amplitude: 0.05)
        let verdict = gate.classify(microphone: person, system: system)
        XCTAssertFalse(verdict.isEcho, "quieter than the other side, but not a copy of it")
        XCTAssertLessThan(verdict.correlation, 0.15)
    }

    func testThePersonTalkingOverAFaintLeakIsStillThePerson() {
        var gate = CrossTalkGate()
        let system = noise(5_120, seed: 12, amplitude: 0.2)
        let microphone = mixed(noise(5_120, seed: 13, amplitude: 0.15), delayed(system, by: 480, gain: 0.05))
        XCTAssertFalse(gate.classify(microphone: microphone, system: system).isEcho)
    }

    /// The person starts talking right after the other side stops: the hold
    /// ends on its own once the microphone stops matching.
    func testThePersonTakingOverEndsTheHold() {
        var gate = CrossTalkGate()
        let system = noise(5_120, seed: 14, amplitude: 0.2)
        XCTAssertTrue(gate.classify(microphone: delayed(system, by: 480, gain: 0.5), system: system).isEcho)
        var verdicts: [Bool] = []
        for block in 0..<8 {
            let other = noise(1_600, seed: 300 + UInt64(block), amplitude: 0.2)
            let person = noise(1_600, seed: 400 + UInt64(block), amplitude: 0.15)
            verdicts.append(gate.classify(microphone: person, system: other).isEcho)
        }
        XCTAssertEqual(verdicts.suffix(3), [false, false, false])
    }

    func testAQuietSystemSideCannotBeAnEchoSource() {
        var gate = CrossTalkGate()
        let system = noise(5_120, seed: 15, amplitude: 0.002)
        let microphone = delayed(system, by: 480, gain: 1)
        XCTAssertFalse(gate.classify(microphone: microphone, system: system).isEcho)
    }

    func testMismatchedOrEmptyBlocksAreNotEcho() {
        var gate = CrossTalkGate()
        XCTAssertFalse(gate.classify(microphone: [], system: []).isEcho)
        XCTAssertFalse(gate.classify(microphone: [0.1, 0.2], system: [0.1]).isEcho)
    }

    func testRMS() {
        XCTAssertEqual(CrossTalkGate.rms([Float]()), 0)
        XCTAssertEqual(CrossTalkGate.rms([0.5, -0.5, 0.5, -0.5] as [Float]), 0.5, accuracy: 0.0001)
    }
}
