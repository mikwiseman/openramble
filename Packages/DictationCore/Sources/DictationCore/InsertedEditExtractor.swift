import Foundation

/// Selecting the edit of the inserted fragment from the contents of another field.
///
/// Given: what the field was like immediately after insertion, where our fragment is in it and what
/// the field became later. The common prefix and suffix of the two states are cut off; if
/// everything that has changed lies inside our fragment - this is an edit of the dictation.
/// Edits of someone else's text and additions after insertion do not concern us
/// construction: their modified middle goes beyond the boundaries of the fragment.
public enum InsertedEditExtractor {
    public struct Edit: Equatable {
        /// The fragment as it was inserted.
        public let original: String
        /// Fragment after human editing.
        public let edited: String
    }

    public static func extract(
        baseline: String,
        current: String,
        inserted: String
    ) -> Edit? {
        guard baseline != current, !inserted.isEmpty else { return nil }
        // The fragment is searched from the end: insertion was the last operation, and when
        // repeating the text in the field, our instance is the one closest to the tail.
        guard let insertedRange = baseline.range(of: inserted, options: .backwards) else {
            return nil
        }

        let baselineChars = Array(baseline)
        let currentChars = Array(current)

        var prefix = 0
        while prefix < baselineChars.count, prefix < currentChars.count,
              baselineChars[prefix] == currentChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < baselineChars.count - prefix, suffix < currentChars.count - prefix,
              baselineChars[baselineChars.count - 1 - suffix]
                  == currentChars[currentChars.count - 1 - suffix] {
            suffix += 1
        }

        // Changed baseline in character indices.
        let changedStart = prefix
        let changedEnd = baselineChars.count - suffix
        let insertedStart = baseline.distance(from: baseline.startIndex, to: insertedRange.lowerBound)
        let insertedEnd = baseline.distance(from: baseline.startIndex, to: insertedRange.upperBound)

        // The edit must lie entirely within the inserted fragment.
        guard changedStart >= insertedStart, changedEnd <= insertedEnd else { return nil }
        if changedStart == changedEnd {
            // Nothing was deleted from baseline - the person just ADDED text.
            // Adding at the border of a fragment is adding your own, not
            // our edit: only an insertion strictly inside is considered an edit.
            guard changedStart > insertedStart, changedStart < insertedEnd else { return nil }
        }

        // Fragment after editing: its length has changed by the difference in field lengths.
        let delta = currentChars.count - baselineChars.count
        let editedStart = insertedStart
        let editedEnd = insertedEnd + delta
        guard editedStart >= 0, editedEnd <= currentChars.count, editedStart <= editedEnd else {
            return nil
        }

        let edited = String(currentChars[editedStart..<editedEnd])
        guard !edited.isEmpty else { return nil }
        return Edit(original: inserted, edited: edited)
    }
}
