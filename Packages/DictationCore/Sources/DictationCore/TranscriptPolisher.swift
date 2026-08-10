import Foundation

/// Deterministic refinement of recognized text.
///
/// No language models: only what can be tested and predicted.
/// Edits here do not change the meaning - they remove traces of the fact that the text came from
/// recognition, and was not typed by hand.
///
/// We do NOT consciously do this: we do not expand the numerals (“twenty-five” → “25”)
/// - in Russian it depends on declensions and cases and breaks more than it fixes.
public enum TranscriptPolisher {
    /// Transform the recognized text into a form suitable for insertion.
    ///
    /// Protected spans (`ProtectedSpan`) are not affected by any operation.
    /// Spans are recalculated before each step, rather than being counted once:
    /// the previous step could have shifted the offsets, and the “floating” range is exactly that
    /// class of error due to which such systems rot. Detection is clean and
    /// idempotent, so recalculation costs nothing and changes nothing.
    public static func polish(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        result = collapseWhitespace(in: result, protecting: spans(of: result))
        result = fixSpacingAroundPunctuation(in: result, protecting: spans(of: result))
        result = capitalizeFirstLetter(of: result, protecting: spans(of: result))
        return result
    }

    private static func spans(of text: String) -> [ProtectedSpan] {
        ProtectedSpanDetector.detect(in: text)
    }

    /// Collapse duplicate spaces while preserving newlines.
    static func collapseWhitespace(in text: String) -> String {
        collapseWhitespace(in: text, protecting: [])
    }

    /// The same, but the spaces inside the protected piece remain as is: in
    /// the code lies in the backticks, and the alignment in it is significant.
    static func collapseWhitespace(in text: String, protecting spans: [ProtectedSpan]) -> String {
        guard !spans.isEmpty else {
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                }
                .joined(separator: "\n")
        }

        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)
        var spanIndex = 0
        var index = 0

        while index < characters.count {
            while spanIndex < spans.count, spans[spanIndex].range.upperBound <= index {
                spanIndex += 1
            }
            if spanIndex < spans.count, spans[spanIndex].range.contains(index) {
                let span = spans[spanIndex]
                result.append(contentsOf: characters[span.range])
                index = span.range.upperBound
                continue
            }

            let character = characters[index]
            if character == " " || character == "\t" {
                // The space in front of the protected piece also collapses - it is not his.
                if result.last != " ", result.last != "\n" { result.append(" ") }
                index += 1
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// Remove the space before the punctuation mark and put it there after it,
    /// where it is definitely missing.
    ///
    /// Space insertion is deliberately careful. The model itself transforms
    /// “three and fourteen hundredths” in “3.14”, and the period appears in versions
    /// (“2.0.1”), domains (“wai.computer”) and abbreviations (“etc.”); colon -
    /// in links (“https://”) and time (“12:30”). Previously, a space was placed after
    /// any point, and everything listed fell apart - tested on the real
    /// model output.
    ///
    /// Therefore, the condition for a period and a colon remains the same: a space is placed
    /// only before a capital letter, that is, when a new sentence begins.
    ///
    /// The “space only before the capital” guard remains after the appearance
    /// spans: it and the span model are filtered along different axes. The guard is watching
    /// what comes AFTER the sign (this is what `3.14`, `wai.computer`, `etc.` are protected by,
    /// `https://`, `12:30` - there is a lowercase or a number next), span looks at WHAT
    /// is a token. Removing the guards, since there are spans, is tempting
    /// error: numbers, domains and abbreviations do not become spans and protections
    /// will be deprived. Spans fix the only defect in the guard - `TextPipeline.Output`.
    static func fixSpacingAroundPunctuation(in text: String) -> String {
        fixSpacingAroundPunctuation(in: text, protecting: [])
    }

    static func fixSpacingAroundPunctuation(
        in text: String,
        protecting spans: [ProtectedSpan]
    ) -> String {
        let closing: Set<Character> = [",", ".", "!", "?", ";", ":", "…"]

        /// Characters after which a space is always needed if there is a letter next.
        ///
        /// “first, second” the model always gives, and there is no capital letter there -
        /// with the condition “only before the capital” the enumeration remained
        /// stuck together. These signs do not have a single spelling where the letter is
        /// right to the point: the only such place at the comma is the decimal
        /// a fraction, and then there is a number, and the rule does not touch it.
        let alwaysSeparating: Set<Character> = [",", "!", "?", ";", "…"]

        var result = ""
        result.reserveCapacity(text.count)

        let characters = Array(text)
        var spanIndex = 0
        var index = 0
        while index < characters.count {
            // The protected piece is carried verbatim: this is where `Foo.Bar`
            // stops turning into `Foo. Bar`.
            while spanIndex < spans.count, spans[spanIndex].range.upperBound <= index {
                spanIndex += 1
            }
            if spanIndex < spans.count, spans[spanIndex].range.contains(index) {
                let span = spans[spanIndex]
                result.append(contentsOf: characters[span.range])
                index = span.range.upperBound
                continue
            }

            let character = characters[index]

            if closing.contains(character) {
                // The space before the punctuation mark is a recognition artifact.
                while result.last == " " { result.removeLast() }
                result.append(character)

                if let next = index + 1 < characters.count ? characters[index + 1] : nil,
                   next.isUppercase || (alwaysSeparating.contains(character) && next.isLetter) {
                    result.append(" ")
                }
                index += 1
                continue
            }

            result.append(character)
            index += 1
        }
        return result
    }

    /// Capitalize the first letter - recognition often gives a lowercase one.
    static func capitalizeFirstLetter(of text: String) -> String {
        capitalizeFirstLetter(of: text, protecting: [])
    }

    /// The identifier at the beginning of the dictation does not receive a capitalization: dictated
    /// the first word of `onTextInserted` is a name, not the beginning of a sentence, and
    /// `OnTextInserted` would just be a different name.
    static func capitalizeFirstLetter(
        of text: String,
        protecting spans: [ProtectedSpan]
    ) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        guard !spans.contains(where: { $0.range.contains(0) }) else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
