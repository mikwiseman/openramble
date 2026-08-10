import Foundation

/// Convolution of typography to the writing that a person would type by hand.
///
/// Why is the stage needed now, before any language model:
///
/// 1. Applications with “smart” substitution (Notion, Pages, Mail) are rewritten in
/// The field has straight quotes in double quotes, and a hyphen in a dash. `InsertedEditExtractor`
/// compares what was inserted with what was re-read, and after such substitution
/// the comparison ceases to converge - learning from edits silently dies.
/// 2. Invisible characters come through the dictionary: `written` person inserts
/// copy-paste, and non-breaking space, BOM and soft hyphen in the settings
/// not visible at all.
/// 3. Similar characters break the span model itself: `U+2212` MINUS before the letter
/// makes `−x` a non-flag.
///
/// The table is closed and small on purpose. Everything that makes sense remains: Christmas trees -
/// correct Russian typography, a dash differs from a hyphen in the case,
/// `TranscriptPolisher` owns ellipses.
enum TypographyFold {
    /// Exactly twelve characters. An empty line means “delete”.
    static let table: [Character: String] = [
        // Invisible spaces → regular space.
        "\u{00A0}": " ",   // NO-BREAK SPACE
        "\u{202F}": " ",   // NARROW NO-BREAK SPACE
        "\u{2009}": " ",   // THIN SPACE
        // Invisible at all → delete.
        "\u{200B}": "",    // ZERO WIDTH SPACE
        "\u{FEFF}": "",    // ZERO WIDTH NO-BREAK SPACE / BOM
        "\u{00AD}": "",    // SOFT HYPHEN
        // Paired quotes → straight ones.
        "\u{2018}": "'",   // LEFT SINGLE QUOTATION MARK
        "\u{2019}": "'",   // RIGHT SINGLE QUOTATION MARK
        "\u{201C}": "\"",  // LEFT DOUBLE QUOTATION MARK
        "\u{201D}": "\"",  // RIGHT DOUBLE QUOTATION MARK
        // Similar to hyphen and dash → canonical.
        "\u{2212}": "-",   // MINUS SIGN
        "\u{2015}": "—",   // HORIZONTAL BAR → EM DASH
    ]

    static func fold(_ text: String) -> String {
        fold(text, protecting: [])
    }

    /// Collapse everything except the protected pieces.
    ///
    /// There is code inside the backticks: there is a significant quote, and replacing it would break it.
    static func fold(_ text: String, protecting spans: [ProtectedSpan]) -> String {
        guard !text.isEmpty else { return text }

        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)

        var spanIndex = 0
        var index = 0
        while index < characters.count {
            // The spans are sorted and do not intersect—one cursor is enough.
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
            if let replacement = table[character] {
                result.append(replacement)
            } else {
                result.append(character)
            }
            index += 1
        }

        return result
    }
}
