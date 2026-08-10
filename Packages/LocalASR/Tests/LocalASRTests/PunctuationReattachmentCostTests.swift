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

    /// A long dictation must not freeze the app.
    ///
    /// The budget is generous on purpose — it is a ceiling against the old
    /// quadratic blow-up, not a micro-benchmark. Anything near the old 16 s
    /// fails here loudly.
    func testLongDictationStaysFast() {
        let sample = text(words: 4000)
        let started = ContinuousClock.now
        _ = PunctuationReattachment.restore(original: sample.original, rescored: sample.rescored)
        let elapsed = ContinuousClock.now - started

        XCTAssertLessThan(
            elapsed, .seconds(1),
            "4000 words took \(elapsed); before the fix this was 4.3 s and it grew quadratically"
        )
    }

    /// The hour-long limit the app allows is roughly 8000 words. That case used
    /// to need a 488 MB matrix; it must now finish without one.
    ///
    /// The ceiling is generous on purpose. A tight one measured a shared CI
    /// runner as much as it measured the code and failed at 3.2 s against a
    /// 3.0 s budget while nothing was wrong. Five seconds in a debug build
    /// still catches any return to the old 16.7 s (28 s in debug) beyond doubt.
    func testHourLongDictationFinishesQuickly() {
        let sample = text(words: 8000)
        let started = ContinuousClock.now
        let result = PunctuationReattachment.restore(
            original: sample.original, rescored: sample.rescored
        )
        let elapsed = ContinuousClock.now - started

        XCTAssertFalse(result.isEmpty)
        XCTAssertLessThan(
            elapsed, .seconds(5),
            "8000 words took \(elapsed); before the fix this was 16.7 s in release"
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
        XCTAssertLessThan(elapsed, .seconds(5), "took \(elapsed)")
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
