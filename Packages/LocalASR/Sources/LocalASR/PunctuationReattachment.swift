import Foundation

/// Return punctuation marks lost by the dictionary resorer.
///
/// Measurement in `docs/benchmarks.md`: on long records the resorer left 347 characters
/// out of 450 - it replaces the word along with the punctuation stuck to it. Defect
/// library, but our call (`FluidAudioAdapter.rescore`), so it works
/// a wrapper around the result, not an edit to FluidAudio.
///
/// The seam is intentionally at the level of strings, not tokens: both sides are a regular `String`,
/// therefore the function is pure and is checked without a model at all.
///
/// Signs are removed **only from the edges** of the field, the middle is not touched. This and
/// protects `3.14`, `etc`, `https://`, `don't` and `typescript`.
///
/// Three invariants on which the tests are based:
/// 1. not a single sign given by the resorer is deleted;
/// 2. new signs do not appear - only from the union of both sides;
/// 3. **words never change** - otherwise the return of punctuation would be canceled
/// dictionary editing, for which the resorer works.
enum PunctuationReattachment {
    /// The only public entry point.
    static func restore(original: String, rescored: String) -> String {
        guard original != rescored else { return rescored }
        guard !original.isEmpty, !rescored.isEmpty else { return rescored }

        let originalFields = fields(original)
        let rescoredFields = fields(rescored)
        guard !originalFields.isEmpty, !rescoredFields.isEmpty else { return rescored }

        let steps = align(originalFields, rescoredFields)

        // Fuse. If the texts diverge too much, understand which
        // where the sign belongs is no longer possible, and inventing punctuation is worse than
        // lose her. This is exactly today's behavior - and it is being tested.
        //
        // The denominator is the short side, not the resorer side. Word break
        // (“Postgres” → “Post gres”) legally increases the number of fields on the right, and
        // division into them would suppress exactly the case for which everything was written.
        // Only exact matches are counted: if the texts are completely different
        // alignment will still give continuous replacements, and they do not serve as a signal.
        let matched = steps.filter { if case .match = $0 { return true } else { return false } }.count
        let anchor = min(originalFields.count, rescoredFields.count)
        guard anchor > 0, Double(matched) / Double(anchor) >= 0.5 else { return rescored }

        var rendered: [Field] = []
        // Where the sign taken from the original sat. Needed because word break
        // comes as a tail from insertions: the sign must reach the last piece,
        // otherwise "postgres." → “Post. gres" instead of "Post gres."
        var borrowedTrailAt: Int?

        for step in steps {
            switch step {
            case let .match(originalIndex, rescoredIndex),
                 let .substitution(originalIndex, rescoredIndex):
                let source = originalFields[originalIndex]
                var field = rescoredFields[rescoredIndex]
                // The resorer’s own sign is always more important: he didn’t lose anything there.
                if field.lead.isEmpty { field.lead = source.lead }
                var borrowed = false
                if field.trail.isEmpty, !source.trail.isEmpty {
                    field.trail = source.trail
                    borrowed = true
                }
                rendered.append(field)
                borrowedTrailAt = borrowed ? rendered.count - 1 : nil

            case let .insertion(rescoredIndex):
                // The resorer split the word into several - we transfer it as is,
                // but we take the borrowed sign with us to the end of the gap.
                var field = rescoredFields[rescoredIndex]
                if let source = borrowedTrailAt,
                   source == rendered.count - 1,
                   field.trail.isEmpty {
                    field.trail = rendered[source].trail
                    rendered[source].trail = ""
                    rendered.append(field)
                    borrowedTrailAt = rendered.count - 1
                } else {
                    rendered.append(field)
                    borrowedTrailAt = nil
                }

            case let .deletion(originalIndex):
                // Resorer glued several words into one. The sign only gives
                // last deleted field, and only if the receiver has nothing
                // lose: restore "pull, request" from "pull request"
                // would mean inventing punctuation within the term.
                guard !rendered.isEmpty, !originalFields[originalIndex].trail.isEmpty else { continue }
                if rendered[rendered.count - 1].trail.isEmpty {
                    rendered[rendered.count - 1].trail = originalFields[originalIndex].trail
                }
            }
        }

        return rendered.map(\.whole).joined()
    }

    // MARK: - Fields

    /// The field is one non-whitespace piece with spaces in front of it.
    ///
    /// Spaces are stored to put the text back together without reformatting:
    /// Line breaks and alignment remain the same as they were given by the resorer.
    struct Field: Equatable {
        var spacingBefore: String
        var lead: String
        var core: String
        var trail: String

        var whole: String { spacingBefore + lead + core + trail }
    }

    /// Signs that are removed from the edges.
    ///
    /// There is no hyphen here intentionally: `-x` is a switch, not a signed word, and
    /// You can’t tear off the hyphen from him.
    private static let marks: Set<Character> = [
        ".", ",", "!", "?", ":", ";", "…",
        "«", "»", "\"", "'", "(", ")", "—", "–",
    ]

    static func fields(_ text: String) -> [Field] {
        let characters = Array(text)
        var result: [Field] = []
        var index = 0

        while index < characters.count {
            var spacing = ""
            while index < characters.count, characters[index].isWhitespace {
                spacing.append(characters[index])
                index += 1
            }
            guard index < characters.count else {
                // We attach trailing spaces to the last field so that the assembly
                // returned the text byte-by-byte.
                if !spacing.isEmpty, !result.isEmpty {
                    result[result.count - 1].trail += spacing
                }
                break
            }

            var token = ""
            while index < characters.count, !characters[index].isWhitespace {
                token.append(characters[index])
                index += 1
            }
            result.append(split(token: token, spacingBefore: spacing))
        }
        return result
    }

    private static func split(token: String, spacingBefore: String) -> Field {
        var characters = Array(token)
        var lead = ""
        var trail = ""

        while let first = characters.first, marks.contains(first) {
            lead.append(first)
            characters.removeFirst()
        }
        while let last = characters.last, marks.contains(last) {
            trail.insert(last, at: trail.startIndex)
            characters.removeLast()
        }

        // A field entirely of characters is an independent “word” (a dash in the role
        // links). Taking it to lead and trail would mean losing it when
        // alignment.
        guard !characters.isEmpty else {
            return Field(spacingBefore: spacingBefore, lead: "", core: token, trail: "")
        }
        return Field(
            spacingBefore: spacingBefore,
            lead: lead,
            core: String(characters),
            trail: trail
        )
    }

    // MARK: - Alignment

    enum Step: Equatable {
        case match(Int, Int)
        case substitution(Int, Int)
        case deletion(Int)
        case insertion(Int)
    }

    /// Levenshtein over fields, restricted to a diagonal band.
    ///
    /// The full matrix is what this used to be, and it is unaffordable here:
    /// this runs synchronously inside `transcribe`, after the person has
    /// already released the key and is waiting. Measured on the old code —
    /// 4000 words 7.1 s, 8000 words 28.4 s and a 488 MB `[[Int]]` on top of
    /// the ~500 MB model. An hour-long note, which the app explicitly allows,
    /// froze it for half a minute with nothing on screen.
    ///
    /// The band is exact, not an approximation. A path can only leave a band of
    /// half-width `k` by accumulating more than `k` edits, so a result whose
    /// total cost is `<= k` is provably the same answer the full matrix gives.
    /// When the cost reaches the edge we double the band and try again, ending
    /// at full width in the worst case — so the answer never changes, only the
    /// work needed to reach it.
    ///
    /// This suits the actual input: the two texts differ by the handful of
    /// words the rescorer substituted, so the first band almost always wins.
    static func align(_ left: [Field], _ right: [Field]) -> [Step] {
        let rows = left.count
        let columns = right.count
        guard rows > 0 else { return (0..<columns).map { .insertion($0) } }
        guard columns > 0 else { return (0..<rows).map { .deletion($0) } }

        // Lowercasing inside the loop cost two String allocations per cell —
        // n² of them, and the single biggest constant in the old profile.
        let leftKeys = left.map { $0.core.lowercased() }
        let rightKeys = right.map { $0.core.lowercased() }

        var band = max(16, abs(rows - columns) + 8)
        let widest = max(rows, columns)
        while true {
            if let steps = alignWithinBand(leftKeys, rightKeys, band: band) { return steps }
            if band >= widest { break }
            band = min(band * 2, widest)
        }
        // Unreachable in practice: at full width the band covers every cell and
        // the cost check always succeeds. Kept so the loop cannot spin.
        return alignWithinBand(leftKeys, rightKeys, band: widest, trustResult: true) ?? []
    }

    /// One banded pass. Returns `nil` when the cost reached the band edge and
    /// the answer may therefore be inexact.
    private static func alignWithinBand(
        _ leftKeys: [String],
        _ rightKeys: [String],
        band: Int,
        trustResult: Bool = false
    ) -> [Step]? {
        let rows = leftKeys.count
        let columns = rightKeys.count
        let drift = columns - rows
        let lowestDiagonal = min(0, drift) - band
        let highestDiagonal = max(0, drift) + band
        let rowWidth = highestDiagonal - lowestDiagonal + 1
        // Anything at or above this is "outside the band"; adding to it must not
        // overflow, so it stays far below Int32.max.
        let unreachable: Int32 = Int32(rows + columns + 1)

        var cost = [Int32](repeating: unreachable, count: (rows + 1) * rowWidth)

        // Column index for a cell, or nil when the cell lies outside the band.
        func slot(_ row: Int, _ column: Int) -> Int? {
            let offset = column - (row + lowestDiagonal)
            guard offset >= 0, offset < rowWidth else { return nil }
            return row * rowWidth + offset
        }
        func value(_ row: Int, _ column: Int) -> Int32 {
            guard row >= 0, column >= 0, let index = slot(row, column) else { return unreachable }
            return cost[index]
        }

        if let index = slot(0, 0) { cost[index] = 0 }
        for row in 0...rows {
            let first = max(0, row + lowestDiagonal)
            let last = min(columns, row + highestDiagonal)
            guard first <= last else { continue }
            for column in first...last {
                if row == 0 && column == 0 { continue }
                guard let index = slot(row, column) else { continue }

                var best = unreachable
                if row > 0, column > 0 {
                    let same = leftKeys[row - 1] == rightKeys[column - 1]
                    let diagonal = value(row - 1, column - 1)
                    if diagonal < unreachable { best = min(best, diagonal + (same ? 0 : 1)) }
                }
                if row > 0 {
                    let above = value(row - 1, column)
                    if above < unreachable { best = min(best, above + 1) }
                }
                if column > 0 {
                    let left = value(row, column - 1)
                    if left < unreachable { best = min(best, left + 1) }
                }
                cost[index] = best
            }
        }

        let total = value(rows, columns)
        // Cost at or beyond the half-width means the optimal path could have
        // stepped outside what we computed. Widen rather than answer wrongly.
        guard trustResult || (total < unreachable && Int(total) <= band) else { return nil }

        var steps: [Step] = []
        var row = rows
        var column = columns
        while row > 0 || column > 0 {
            if row > 0, column > 0 {
                let same = leftKeys[row - 1] == rightKeys[column - 1]
                if value(row, column) == value(row - 1, column - 1) + (same ? 0 : 1) {
                    steps.append(same ? .match(row - 1, column - 1) : .substitution(row - 1, column - 1))
                    row -= 1
                    column -= 1
                    continue
                }
            }
            if row > 0, value(row, column) == value(row - 1, column) + 1 {
                steps.append(.deletion(row - 1))
                row -= 1
                continue
            }
            if column > 0 {
                steps.append(.insertion(column - 1))
                column -= 1
                continue
            }
            // Defensive: the traceback must always be able to move. Bailing out
            // here beats looping forever on an unexpected matrix.
            return nil
        }
        return steps.reversed()
    }
}
