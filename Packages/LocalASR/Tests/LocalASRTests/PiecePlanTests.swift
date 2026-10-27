import XCTest
@testable import LocalASR

/// The tests of `apps/cli/src/plan.rs`, on the same synthetic envelopes and
/// with the same expected pieces, so the Mac and the server cut one way.
final class PiecePlanTests: XCTestCase {
    private let s = PiecePlan.framesPerSecond
    private let speechLevel: Float = 0.1

    /// Speech-like loudness: never quiet, never flat. The server's generator.
    private func speech(_ seconds: Int, seed: UInt32) -> [Float] {
        var state = seed &* 2_654_435_761 &+ 1
        return (0..<seconds * s).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return speechLevel * (0.6 + 0.8 * Float(state >> 8) / Float(1 << 24))
        }
    }

    /// Low steady noise, as a quiet room records.
    private func room(_ seconds: Int) -> [Float] {
        (0..<seconds * s).map { 0.002 * (1 + 0.02 * (Float($0 % 7) - 3)) }
    }

    private func put(_ envelope: inout [Float], at seconds: Float, _ words: [Float]) {
        let at = Int(seconds * Float(s))
        envelope.replaceSubrange(at..<at + words.count, with: words)
    }

    func testSilenceAndDigitalSilenceGiveNoPieces() {
        let quiet = room(60)
        XCTAssertEqual(PiecePlan.plan(quiet, span: 0..<quiet.count, cap: 20, gate: true), [])
        let zeros = [Float](repeating: 0, count: 60 * s)
        XCTAssertEqual(PiecePlan.plan(zeros, span: 0..<zeros.count, cap: 20, gate: true), [])
        XCTAssertEqual(PiecePlan.plan([], span: 0..<0, cap: 20, gate: true), [])
    }

    func testAWordInAMinuteOfRoomNoiseGetsASecondOnEachSide() {
        var envelope = room(60)
        put(&envelope, at: 30, speech(1, seed: 1))
        XCTAssertEqual(PiecePlan.plan(envelope, span: 0..<envelope.count, cap: 20, gate: true), [29 * s..<32 * s])
    }

    func testWordsAMomentApartMergeAndWordsFarApartDoNot() {
        var close = room(60)
        put(&close, at: 10, speech(1, seed: 1))
        put(&close, at: 12.5, speech(1, seed: 2))
        XCTAssertEqual(PiecePlan.plan(close, span: 0..<close.count, cap: 20, gate: true), [9 * s..<29 * s / 2])
        var apart = room(60)
        put(&apart, at: 10, speech(1, seed: 1))
        put(&apart, at: 14, speech(1, seed: 2))
        XCTAssertEqual(PiecePlan.plan(apart, span: 0..<apart.count, cap: 20, gate: true),
                       [9 * s..<12 * s, 13 * s..<16 * s])
    }

    func testAClickIsNotSpeech() {
        var envelope = room(60)
        put(&envelope, at: 30, [Float](repeating: speechLevel, count: 4))
        XCTAssertEqual(PiecePlan.plan(envelope, span: 0..<envelope.count, cap: 20, gate: true), [])
        put(&envelope, at: 30, [Float](repeating: speechLevel, count: 5))
        XCTAssertEqual(PiecePlan.plan(envelope, span: 0..<envelope.count, cap: 20, gate: true).count, 1)
    }

    func testContinuousSpeechIsCutAtItsPausesIntoContiguousPieces() {
        var envelope = speech(95, seed: 7)
        let length = envelope.count
        var planted: [Int] = []
        // n = ceil(95 / 16) = 6 pieces; plant a V-shaped dip near each even cut.
        for (k, shift) in zip(1..<6, [75, -95, 20, -40, 100]) {
            let at = k * length / 6 + shift
            for offset in -5...5 { envelope[at + offset] = 0.05 * Float(abs(offset)) / 6 }
            planted.append(at)
        }
        let pieces = PiecePlan.plan(envelope, span: 0..<length, cap: 20, gate: false)
        XCTAssertEqual(pieces.count, 6)
        XCTAssertEqual(pieces.first?.lowerBound, 0)
        XCTAssertEqual(pieces.last?.upperBound, length)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 20 * s })
        XCTAssertEqual(zip(pieces, pieces.dropFirst()).filter { $0.upperBound != $1.lowerBound }.count, 0)
        XCTAssertEqual(pieces.dropFirst().map(\.lowerBound), planted)
    }

    /// `the_mac_cuts_the_same_frames` in plan.rs asserts these same pieces.
    /// Change both, or neither.
    func testTheServerCutsTheSameFrames() {
        var envelope = room(300)
        put(&envelope, at: 12, speech(75, seed: 11))
        put(&envelope, at: 100, speech(3, seed: 12))
        put(&envelope, at: 140, speech(130, seed: 13))
        let pieces = PiecePlan.plan(envelope, span: 0..<envelope.count, cap: 20, gate: true)
        XCTAssertEqual(pieces.map { [$0.lowerBound, $0.upperBound] }, [
            [550, 1163], [1163, 1753], [1753, 2209], [2233, 2891], [2891, 3581], [3581, 4400],
            [4950, 5200], [6950, 7716], [7716, 8508], [8508, 9266], [9266, 9983], [9983, 10819],
            [10821, 11543], [11543, 12148], [12148, 12846], [12846, 13550],
        ])
    }

    func testLongRegionsSplitIntoPiecesNearSixteenSeconds() {
        for (seconds, count) in [(12, 1), (20, 1), (30, 2), (60, 4), (240, 15)] {
            let envelope = speech(seconds, seed: UInt32(seconds))
            let pieces = PiecePlan.plan(envelope, span: 0..<envelope.count, cap: 20, gate: false)
            XCTAssertEqual(pieces.count, count, "\(seconds) s")
            XCTAssertTrue(pieces.allSatisfy { $0.count >= 10 * s && $0.count <= 20 * s }, "\(pieces)")
        }
    }

    func testTheGateNeverReachesOutsideTheSpan() {
        var envelope = room(60)
        put(&envelope, at: 20, speech(10, seed: 4))
        XCTAssertEqual(PiecePlan.plan(envelope, span: 20 * s + 10..<25 * s, cap: 20, gate: true),
                       [20 * s + 10..<25 * s])
    }

    func testPiecesOfAFileAreInSamplesAndEndAtItsLastSample() {
        var envelope = room(100)
        put(&envelope, at: 70, speech(5, seed: 6))
        XCTAssertEqual(PiecePlan.pieces(envelope, samples: 100 * 16_000 - 77, cap: 20), [69 * 16_000..<76 * 16_000])
        var short = room(3)
        put(&short, at: 0.5, speech(2, seed: 1))
        XCTAssertEqual(PiecePlan.pieces(short, samples: 3 * 16_000 - 77, cap: 20), [0..<3 * 16_000 - 77])
    }
}
