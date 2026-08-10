import Foundation

/// Dictionary training for editing the last dictation.
///
/// The editing surface is the application's own window: we do not read other people's
/// applications and do not monitor the keyboard, so the only honest signal is
/// text that the person corrected from us himself. Word by word diff turns edit
/// candidates for replacement.
///
/// The filter is intentionally conservative. Only the pair with the right side studies
/// carries **signal of the term**: a change of writing (“post gerz” → “Postgres”) or
/// brand register (“github” → “GitHub”). Everything else is more of a speech edit
/// (“quickly” → “faster”, “the file” → “a file”), and learning it would mean silently
/// replace the person’s words in the following dictations.
public enum CorrectionLearning {
    /// How many replacements can come out of one edit.
    ///
    /// Editing a dictation is a few terms. When there is more steam in front of us
    /// not an edit, but a different text: inserted translation, rewritten paragraph. From
    /// nothing like this can be taught - not because some of the pairs are bad, but because
    /// what to establish at once dozens of silent rules for future dictations
    /// irreversible, but to say “there is nothing to learn” and ask to correct the terms
    /// in smaller portions - no. Measurement: editing-substitution of 200 words gave
    /// 200 replacements at once.
    static let maximumProposalsPerCorrection = 5

    /// Suggest replacements for edits. It doesn't save anything - it only offers.
    ///
    /// `protecting` - protected spans of the source text. Of these, proposals are not
    /// never built: path, flag or contents of backticks a person rules as
    /// code, not as a term, and turn such an edit into a silent rule
    /// Future dictations are not allowed. An empty list is the same behavior.
    public static func propose(
        original: String,
        edited: String,
        existing: [DictionaryReplacement] = [],
        protecting spans: [ProtectedSpan] = []
    ) -> [DictionaryReplacement] {
        let originalWords = words(from: original)
        let editedWords = words(from: edited)
        guard !originalWords.isEmpty, !editedWords.isEmpty else { return [] }

        let known = Set(existing.map { $0.spoken.lowercased() })
        let protectedWords = Set(
            spans.flatMap { words(from: $0.text) }.map { $0.lowercased() }
        )
        var seen = Set<String>()
        var proposals: [DictionaryReplacement] = []

        for pair in substitutions(from: originalWords, to: editedWords) {
            let spoken = pair.original.joined(separator: " ")
            let written = pair.edited.joined(separator: " ")
            guard spoken.lowercased() != written.lowercased() || spoken != written else {
                continue
            }
            guard looksLikeTerm(spoken: spoken, written: written) else { continue }
            guard !known.contains(spoken.lowercased()) else { continue }
            // At least one word from the protected piece - the sentence is discarded
            // entirely: editing inside the code does not make the term.
            guard !pair.original.contains(where: { protectedWords.contains($0.lowercased()) }) else {
                continue
            }
            // The same pair can appear twice in the text (“open
            // sentry and close sentry"). The second copy in the dictionary is nothing
            // adds, but a person would have to delete it on a separate line.
            guard seen.insert("\(spoken.lowercased())\u{0}\(written)").inserted else { continue }
            // Terms from the edit are not written in Latin - just like in the starter
            // set: the inflected stem would invent matches.
            proposals.append(DictionaryReplacement(spoken: spoken, written: written, inflects: false))
        }
        guard proposals.count <= maximumProposalsPerCorrection else { return [] }
        return proposals
    }

    // MARK: - Diff

    private struct Substitution {
        let original: [String]
        let edited: [String]
    }

    /// Pairs “replaced piece → what was replaced with” according to LCS alignment of words.
    ///
    /// Insertions and deletions do not generate replacements: replacement is when both
    /// there is something on the sides. Pieces longer than three words are discarded: this is already
    /// a rewritten sentence, not an edit of a term.
    private static func substitutions(
        from original: [String],
        to edited: [String]
    ) -> [Substitution] {
        let table = lcsTable(original.map { $0.lowercased() }, edited.map { $0.lowercased() })
        var result: [Substitution] = []
        var i = original.count
        var j = edited.count
        var pendingOriginal: [String] = []
        var pendingEdited: [String] = []

        func flush() {
            defer {
                pendingOriginal = []
                pendingEdited = []
            }
            guard !pendingOriginal.isEmpty, !pendingEdited.isEmpty else { return }
            guard pendingOriginal.count <= 3, pendingEdited.count <= 3 else { return }
            result.append(
                Substitution(
                    original: pendingOriginal.reversed(),
                    edited: pendingEdited.reversed()
                )
            )
        }

        while i > 0 || j > 0 {
            if i > 0, j > 0, original[i - 1].lowercased() == edited[j - 1].lowercased(),
               original[i - 1] == edited[j - 1] {
                flush()
                i -= 1
                j -= 1
            } else if i > 0, j > 0,
                      original[i - 1].lowercased() == edited[j - 1].lowercased() {
                // The word is the same, but the case is different - this is also an edit.
                pendingOriginal.append(original[i - 1])
                pendingEdited.append(edited[j - 1])
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || table[i][j - 1] >= table[i - 1][j] {
                pendingEdited.append(edited[j - 1])
                j -= 1
            } else {
                pendingOriginal.append(original[i - 1])
                i -= 1
            }
        }
        flush()
        return result.reversed()
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...max(1, a.count) where !a.isEmpty {
            for j in 1...max(1, b.count) where !b.isEmpty {
                table[i][j] = a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table
    }

    // MARK: - Filters

    private static func words(from text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
    }

    /// Does the correction look like the term for which the dictionary was created?
    ///
    /// You cannot check only the Latin alphabet on the right: in a text that is entirely
    /// in Latin, this sign does not mean anything, and the usual editing of speech
    /// would pass for the term. Measurement: “please send me the file” → “…a file”
    /// gave the replacement “the” → “a”, after which each subsequent dictation
    /// silently turned “The report is on the desk” into “A report is on a desk.”
    ///
    /// Therefore, a signal is considered not to be the presence of the Latin alphabet, but its appearance where
    /// it was not there, or a register that a regular word does not have:
    ///
    /// 1. **Change of writing** - there is no Latin on the left, there is on the right. Exactly that
    /// what the term looks like when heard in Cyrillic: “post gerz” → “Postgres”.
    /// 2. **Brand register** - capital not at the beginning of the word: “GitHub”, “macOS”,
    /// "API". Capitalizing only the first letter is not considered a signal: it
    /// is indistinguishable from the beginning of a sentence, and pairs like
    /// “The” → “the” together with its opposite “the” → “The”.
    ///
    /// One Latin letter is not enough for the term: “world” → “a” formally replaces
    /// writing, but as a replacement throughout the text it is too expensive.
    private static func looksLikeTerm(spoken: String, written: String) -> Bool {
        guard written.filter({ $0.isLetter && $0.isASCII }).count >= 2 else { return false }

        let spokenHasLatin = spoken.contains { $0.isLetter && $0.isASCII }
        let writtenHasLatin = written.contains { $0.isLetter && $0.isASCII }
        if !spokenHasLatin, writtenHasLatin { return true }

        return words(from: written).contains { word in
            word.dropFirst().contains { $0.isUppercase && $0.isASCII }
        }
    }
}
