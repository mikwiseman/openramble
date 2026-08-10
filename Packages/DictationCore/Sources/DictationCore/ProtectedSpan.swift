import Foundation

/// A piece of text that, after the dictionary, is not touched by any stage of the pipeline.
///
/// Appeared for a specific defect: the polisher puts a space after the dot before
/// capitalized, and `TextPipeline.Output` turned into `TextPipeline. Output`.
/// The same mechanism covers a more unpleasant one - phonetic replacement,
/// triggered inside a path or backticks.
///
/// The range is stored in character offsets (`Character`), not in `String.Index`
/// and not in `NSRange`: the entire packet is already moving along `Array(text)`, but the translation between
/// `NSRange` and `String.Index` in this repository have already caused a bug once.
public struct ProtectedSpan: Sendable, Equatable, Hashable {
    /// What exactly is the protected piece.
    ///
    /// Recruitment is closed. Each case is not “similar to code”, but specific
    /// writing that a person dictates and expects to see verbatim.
    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        /// The text in backquotes along with the quotes themselves.
        case backticks
        /// File system path or URL.
        case path
        /// Command line switch: `--dry-run`, `-x`, `--out=build/app`.
        case flag
        /// CamelCase or dot ID: `TextPipeline`, `AppState.shared`.
        case identifier
    }

    public let kind: Kind
    /// Character offsets in the text for which the span is calculated.
    public let range: Range<Int>
    /// The span text itself.
    ///
    /// Duplicates `range` intentionally: the “spans have not changed” gate becomes
    /// by comparing strings, and the failed test is read without recalculating the offsets in the head.
    public let text: String

    public init(kind: Kind, range: Range<Int>, text: String) {
        self.kind = kind
        self.range = range
        self.text = text
    }
}

/// Search for protected spans in the text.
///
/// Pure function: the same text always gives the same spans. On this
/// the entire pipeline contract costs - the stages recalculate the spans after each
/// text edits, so in principle there are no “floating” offsets.
///
/// The scan goes from left to right, the spans do not intersect, and if there is a conflict, it wins
/// started earlier and longer.
enum ProtectedSpanDetector {
    static func detect(in text: String) -> [ProtectedSpan] {
        let characters = Array(text)
        var spans: [ProtectedSpan] = []
        var index = 0

        while index < characters.count {
            // Backtics are the first and unconditionally: there is already code inside, and the rest
            // there is nothing to look for rules there.
            if characters[index] == "`", let span = backtickSpan(characters, from: index) {
                spans.append(span)
                index = span.range.upperBound
                continue
            }

            guard isTokenStart(characters, at: index) else {
                index += 1
                continue
            }

            let end = tokenEnd(characters, from: index)
            let token = Array(characters[index..<end])

            if let span = spanForToken(token, startingAt: index) {
                spans.append(span)
            }
            index = end
        }

        return spans
    }

    // MARK: - Baktiki

    /// A pair of the same number of backticks with non-empty content without a line break.
    private static func backtickSpan(_ characters: [Character], from start: Int) -> ProtectedSpan? {
        var openEnd = start
        while openEnd < characters.count, characters[openEnd] == "`" { openEnd += 1 }
        let fenceLength = openEnd - start

        var cursor = openEnd
        while cursor < characters.count {
            if characters[cursor] == "\n" { return nil }
            guard characters[cursor] == "`" else { cursor += 1; continue }

            var closeEnd = cursor
            while closeEnd < characters.count, characters[closeEnd] == "`" { closeEnd += 1 }
            guard closeEnd - cursor == fenceLength else { cursor = closeEnd; continue }
            guard cursor > openEnd else { return nil }

            let range = start..<closeEnd
            return ProtectedSpan(
                kind: .backticks,
                range: range,
                text: String(characters[range])
            )
        }
        return nil
    }

    // MARK: - Tokens

    /// The token begins where the space ended, and only with "non-white space".
    private static func isTokenStart(_ characters: [Character], at index: Int) -> Bool {
        guard !characters[index].isWhitespace else { return false }
        guard index > 0 else { return true }
        return characters[index - 1].isWhitespace
    }

    private static func tokenEnd(_ characters: [Character], from start: Int) -> Int {
        var end = start
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        return end
    }

    /// Parsing one token. The order of checks is from the most specific to the most general.
    private static func spanForToken(_ token: [Character], startingAt start: Int) -> ProtectedSpan? {
        // Tail punctuation belongs to the phrase, not the token: "open /etc/hosts."
        var body = token
        while let last = body.last, isTrailingPunctuation(last) { body.removeLast() }
        guard !body.isEmpty else { return nil }

        let kind: ProtectedSpan.Kind?
        if isFlag(body) {
            kind = .flag
        } else if isPath(body) {
            kind = .path
        } else if isIdentifier(body) {
            kind = .identifier
        } else {
            kind = nil
        }

        guard let kind else { return nil }
        let range = start..<(start + body.count)
        return ProtectedSpan(kind: kind, range: range, text: String(body))
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        ",.!?;:…»\")".contains(character)
    }

    // MARK: - Rules

    /// `--flag`, `--flag=value` or short `-x` of exactly one letter.
    ///
    /// One letter is not a quibble: `-5` is a number, and `-xvf` does not exist in dictation,
    /// but “word-word” does happen, and you can’t turn it into a flag.
    private static func isFlag(_ token: [Character]) -> Bool {
        if token.count >= 3, token[0] == "-", token[1] == "-" {
            guard token[2].isLetter, token[2].isASCII else { return false }
            return true
        }
        if token.count == 2, token[0] == "-" {
            return token[1].isLetter && token[1].isASCII
        }
        return false
    }

    /// Path: a slash and one of three confirmations are required.
    ///
    /// The bare `foo/bar` is not enough - in Russian speech it is “or”, and such combinations
    /// noticeably more than paths from two simple segments.
    private static func isPath(_ token: [Character]) -> Bool {
        guard token.contains("/") else { return false }

        let string = String(token)
        if string.contains("://") { return true }
        if string.hasPrefix("/") || string.hasPrefix("./")
            || string.hasPrefix("../") || string.hasPrefix("~/") {
            return hasNonEmptySegment(string)
        }

        let segments = string.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty }) else { return false }
        guard segments.allSatisfy({ $0.allSatisfy(isPathSegmentCharacter) }) else { return false }

        let slashes = token.filter { $0 == "/" }.count
        let hasRichSegment = segments.contains { $0.contains(".") || $0.contains("_") || $0.contains("-") }
        return slashes >= 2 || hasRichSegment
    }

    private static func hasNonEmptySegment(_ string: String) -> Bool {
        string.split(separator: "/").contains { !$0.isEmpty }
    }

    private static func isPathSegmentCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        if character.isLetter || character.isNumber { return true }
        return "._+@-".contains(character)
    }

    /// CamelCase or dot identifier with a capital in at least one segment.
    private static func isIdentifier(_ token: [Character]) -> Bool {
        guard token.allSatisfy({ $0.isASCII }) else { return false }

        if token.contains(".") {
            let segments = String(token).split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty }) else { return false }
            guard segments.allSatisfy(isIdentifierSegment) else { return false }
            // Domains and versions are cut off here: `wai.computer` and `2.0.1` do not
            // neither capital nor CamelCase - and both are already protected by the polisher guard.
            return segments.contains { segment in
                segment.first?.isUppercase == true || isCamelCase(Array(segment))
            }
        }

        return isCamelCase(token)
    }

    private static func isIdentifierSegment(_ segment: Substring) -> Bool {
        guard let first = segment.first, first.isLetter || first == "_" else { return false }
        return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Two CamelCase forms, both real.
    ///
    /// The first is the transition from lowercase to uppercase: `onTextInserted`, `TextPipeline`.
    /// The second is an abbreviation followed by the word: `URLSession`,
    /// `NSString`, `HTTPServer`. In the second there is not a single transition lower→upper,
    /// even without a separate rule, such names would remain unprotected.
    ///
    /// `API`, `JSON`, `HTTP` do not fit any of them: there is nothing behind the abbreviation
    /// does not start. They don’t need protection - there is no point inside, there is nothing to break.
    ///
    /// Protecting a single word is not a formality: without it `capitalizeFirstLetter`
    /// turns the dictated first word `onTextInserted` into `OnTextInserted`.
    private static func isCamelCase(_ token: [Character]) -> Bool {
        guard token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }

        for (previous, current) in zip(token, token.dropFirst())
        where previous.isLowercase && current.isUppercase {
            return true
        }

        for index in 0..<max(0, token.count - 2)
        where token[index].isUppercase
            && token[index + 1].isUppercase
            && token[index + 2].isLowercase {
            return true
        }

        return false
    }
}
