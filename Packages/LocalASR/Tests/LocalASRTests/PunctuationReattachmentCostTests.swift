import XCTest
@testable import LocalASR

/// The cost of restoring punctuation, not just its correctness.
///
/// This runs synchronously inside `transcribe`, after the user has already
/// released the key and is waiting for text. Measured before the fix: 4000
/// words took 4.3 s and 122 MB, 8000 words took 16.7 s and 488 MB — on top of
/// the ~500 MB model. A 50-minute note therefore froze the app for a quarter of
/// a minute with nothing on screen.
final class PunctuationReattachmentCostTests: XCTestCase {
    private func text(words: Int, changeEvery: Int = 50) -> (original: String, rescored: String) {
        var original: [String] = []
        var rescored: [String] = []
        for index in 0..<words {
            let word = "слово\(index % 900)"
            original.append(index % 25 == 0 ? word + "," : word)
            // A substitution every so often is what the rescorer actually does.
            rescored.append(index % changeEvery == 0 ? "Term\(index)" : word)
        }
        return (original.joined(separator: " "), rescored.joined(separator: " "))
    }

    /// The quadratic blow-up must not return — measured as a shape, not a
    /// stopwatch.
    ///
    /// Every absolute-seconds budget this test carried measured the machine
    /// as much as the code: 5 s passed on an idle laptop, failed at 6.3 s on
    /// a shared CI runner, and read 938 s on the same laptop under swap
    /// thrash — all on identical, healthy code. The property actually being
    /// guarded is the SHAPE of the cost: the old full-matrix path grew
    /// quadratically (4× the words → ~16× the time), the banded fix grows
    /// linearly (4× the words → ~4× the time). A ratio of two runs on the
    /// same machine in the same second is immune to how fast that machine
    /// happens to be.
    func testCostScalesLinearlyNotQuadratically() {
        // One warm-up so allocator and cache effects don't land on either side.
        let warm = text(words: 500)
        _ = PunctuationReattachment.restore(original: warm.original, rescored: warm.rescored)

        let small = text(words: 2000)
        let smallStarted = ContinuousClock.now
        _ = PunctuationReattachment.restore(original: small.original, rescored: small.rescored)
        let smallElapsed = ContinuousClock.now - smallStarted

        let large = text(words: 8000)
        let largeStarted = ContinuousClock.now
        let result = PunctuationReattachment.restore(
            original: large.original, rescored: large.rescored
        )
        let largeElapsed = ContinuousClock.now - largeStarted

        XCTAssertFalse(result.isEmpty)
        let ratio = Double(largeElapsed.components.attoseconds)
            / max(1, Double(smallElapsed.components.attoseconds))
        // Linear ≈ 4, quadratic ≈ 16. Ten separates them with room for noise
        // on both sides.
        XCTAssertLessThan(
            ratio, 10,
            "4× the words cost \(String(format: "%.1f", ratio))× the time — the quadratic path is back"
        )
    }

    /// Two texts with nothing in common must not be ground through a full
    /// matrix. The work budget gives up instead, and giving up means leaving
    /// the rescorer's text alone — the same thing the 0.5 fuse already does.
    func testHopelesslyDifferentTextsGiveUpInsteadOfGrinding() {
        let original = (0..<6000).map { "aaa\($0)" }.joined(separator: " ")
        let rescored = (0..<6000).map { "zzz\($0)" }.joined(separator: " ")

        let started = ContinuousClock.now
        let result = PunctuationReattachment.restore(original: original, rescored: rescored)
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(result, rescored, "nothing recoverable — the rescorer's text stands")
        // The behavioral assert above is the test. The clock is only a
        // runaway backstop, set far above any honest machine so it cannot
        // measure load instead of code.
        XCTAssertLessThan(elapsed, .seconds(60), "took \(elapsed) — the give-up path is grinding")
    }

    /// Speed must not have been bought with correctness: the three invariants
    /// still hold on a long text.
    func testInvariantsSurviveOnLongText() {
        let sample = text(words: 3000)
        let result = PunctuationReattachment.restore(original: sample.original, rescored: sample.rescored)

        let cores = { (text: String) in PunctuationReattachment.fields(text).map(\.core) }
        XCTAssertEqual(cores(result), cores(sample.rescored), "words must stay the rescorer's words")

        let marks = { (text: String) in text.filter { ".,!?:;…«»\"'()—–".contains($0) }.count }
        XCTAssertGreaterThanOrEqual(marks(result), marks(sample.rescored))
        XCTAssertLessThanOrEqual(marks(result), max(marks(sample.original), marks(sample.rescored)))
    }
}

/// The banded alignment must give the SAME answer as the full matrix.
///
/// Speed is worthless if it changed the result. The band is exact by argument —
/// a path cannot leave a band of half-width k without accumulating more than k
/// edits — but an argument is not a test, so this compares against a plain
/// reference implementation on inputs designed to stress the band: scattered
/// substitutions, word splits and merges, insertions and deletions at both
/// ends, and lengths that differ.
final class BandedAlignmentEquivalenceTests: XCTestCase {
    /// Deliberately naive: the full matrix this replaced.
    private func referenceAlign(
        _ left: [PunctuationReattachment.Field],
        _ right: [PunctuationReattachment.Field]
    ) -> [PunctuationReattachment.Step] {
        let rows = left.count
        let columns = right.count
        guard rows > 0 else { return (0..<columns).map { .insertion($0) } }
        guard columns > 0 else { return (0..<rows).map { .deletion($0) } }

        var cost = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        for row in 0...rows { cost[row][0] = row }
        for column in 0...columns { cost[0][column] = column }
        for row in 1...rows {
            for column in 1...columns {
                let same = left[row - 1].core.lowercased() == right[column - 1].core.lowercased()
                cost[row][column] = min(
                    cost[row - 1][column - 1] + (same ? 0 : 1),
                    cost[row - 1][column] + 1,
                    cost[row][column - 1] + 1
                )
            }
        }

        var steps: [PunctuationReattachment.Step] = []
        var row = rows
        var column = columns
        while row > 0 || column > 0 {
            if row > 0, column > 0 {
                let same = left[row - 1].core.lowercased() == right[column - 1].core.lowercased()
                if cost[row][column] == cost[row - 1][column - 1] + (same ? 0 : 1) {
                    steps.append(same ? .match(row - 1, column - 1) : .substitution(row - 1, column - 1))
                    row -= 1; column -= 1; continue
                }
            }
            if row > 0, cost[row][column] == cost[row - 1][column] + 1 {
                steps.append(.deletion(row - 1)); row -= 1; continue
            }
            steps.append(.insertion(column - 1)); column -= 1
        }
        return steps.reversed()
    }

    /// Deterministic pseudo-random, so a failure is reproducible.
    private struct Seeded {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    func testBandedMatchesTheFullMatrixOnRandomEdits() {
        var random = Seeded(state: 20260810)

        for trial in 0..<200 {
            let count = 5 + random.next(60)
            var original: [String] = []
            var rescored: [String] = []
            for index in 0..<count {
                let word = "w\(random.next(12))"
                original.append(word)
                switch random.next(10) {
                case 0: rescored.append("X\(index)")             // substitution
                case 1: break                                     // deletion
                case 2: rescored.append(word); rescored.append("Y\(index)")  // insertion
                case 3: rescored.append(word); rescored.append(word)         // split
                default: rescored.append(word)
                }
            }
            guard !rescored.isEmpty else { continue }

            let left = PunctuationReattachment.fields(original.joined(separator: " "))
            let right = PunctuationReattachment.fields(rescored.joined(separator: " "))

            let banded = PunctuationReattachment.align(left, right)
            let reference = referenceAlign(left, right)

            // Several optimal alignments can exist, so compare the property that
            // matters — total edit cost — plus the shape of the result.
            let editCost = { (steps: [PunctuationReattachment.Step]) in
                steps.filter { if case .match = $0 { return false } else { return true } }.count
            }
            XCTAssertEqual(
                editCost(banded), editCost(reference),
                "trial \(trial): banded found a worse alignment than the full matrix"
            )
        }
    }

    /// Lengths far apart force the band wider than its first guess.
    func testBandWidensWhenTheTextsDivergeALot() {
        let left = PunctuationReattachment.fields((0..<120).map { "a\($0)" }.joined(separator: " "))
        let right = PunctuationReattachment.fields((0..<120).map { "b\($0)" }.joined(separator: " "))

        let banded = PunctuationReattachment.align(left, right)
        let reference = referenceAlign(left, right)

        let editCost = { (steps: [PunctuationReattachment.Step]) in
            steps.filter { if case .match = $0 { return false } else { return true } }.count
        }
        XCTAssertEqual(editCost(banded), editCost(reference), "every word differs — the band must widen")
    }
}
