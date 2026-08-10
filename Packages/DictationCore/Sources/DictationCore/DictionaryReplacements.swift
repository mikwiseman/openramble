import Foundation

/// Custom replacement: how it is recognized → how it should be written.
///
/// This is why a dictionary is needed: the model does not know the names that the user
/// lives every day, and consistently writes “sentry” instead of “Sentry”.
public struct DictionaryReplacement: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// What the model heard.
    public var spoken: String
    /// What should appear in the text.
    public var written: String
    /// Whether to wait for case endings for the entry.
    ///
    /// A property of a record, not an inference from its letters. "Deploy" is a word he has
    /// “deploy” and “deploy”. “Komet” is not a word, but a recognition flaw: it has
    /// there are no cases, but there is a “comet”, which the inflected stem “comets-”
    /// ate along with the term. Measuring it was worth it: real Russian words in
    /// the kill radius of the set was 89, of which four families are ordinary speech.
    public var inflects: Bool
    /// Whether to keep the term away from the acoustic prompt.
    ///
    /// A property of a record, not a list in someone else's file. There are terms whose
    /// Cyrillic sound - a common Russian word: “deploy” catches “warm”,
    /// “Sentry” - “in the center”, “commit” - “comet”. Sees the similarity of the library
    /// through alphabets (`sim("center", Sentry) = 0.83`), and English
    /// The CTC model will always value the Latin term higher than the Cyrillic word by
    /// the same entry. Worse, the “center” in an honest Russian phrase and the “center” in
    /// in place of Sentry - the same text, and no threshold will separate them.
    /// Such terms remain in the dictionary of replacements, whose rules are not used in ordinary speech.
    /// touch (docs/benchmarks.md).
    ///
    /// Previously, this was a hardcoded list of three words in `VocabularyBoost`.
    /// A person’s own terms have never been included in it, but add your own
    /// he couldn't at all.
    public var noAcousticBoost: Bool

    public init(
        id: UUID = UUID(),
        spoken: String,
        written: String,
        inflects: Bool = true,
        noAcousticBoost: Bool = false
    ) {
        self.id = id
        self.spoken = spoken
        self.written = written
        self.inflects = inflects
        self.noAcousticBoost = noAcousticBoost
    }

    /// Your own analysis is needed because of `inflects` and `noAcousticBoost`: in dictionaries,
    /// there are no keys recorded before their appearance. The absence of `inflects` is
    /// “bends”, as it was; absence of `noAcousticBoost` - “boosts”,
    /// because it used to be a list, not a record, that solved it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        spoken = try container.decode(String.self, forKey: .spoken)
        written = try container.decode(String.self, forKey: .written)
        inflects = try container.decodeIfPresent(Bool.self, forKey: .inflects) ?? true
        noAcousticBoost = try container.decodeIfPresent(Bool.self, forKey: .noAcousticBoost) ?? false
    }
}

/// Applying a dictionary to recognized text.
public enum DictionaryReplacements {
    /// Replace all occurrences along word boundaries.
    ///
    /// Borders are required: without them, replacing “code” → “code” would turn
    /// "encoding" to "encoding". The input register is ignored because
    /// recognition does not guarantee its stability.
    ///
    /// There are two passes, and the order is important. First, an exact match with the cases -
    /// it is responsible for everything that is literally written in the dictionary. Then
    /// phonetic selection: it catches those spellings of the term that are in the dictionary
    /// no and cannot be, because the model writes the same word
    /// differently in different phrases. Measurement of both passes is in docs/benchmarks.md.
    /// The passes are split (`applyExact` + `applyPhonetic`) because between
    /// they are the detection of protected spans: exact replacement - explicit will
    /// human and goes before spans even exist, and the phonetic
    /// additional is a guess and must bypass spans. Order is the rule
    /// priority; There is no need to write separate precedent rules.
    public static func apply(
        _ replacements: [DictionaryReplacement],
        to text: String,
        phoneticMatching: Bool = true
    ) -> String {
        let exact = applyExact(replacements, to: text)
        guard phoneticMatching else { return exact }
        return applyPhonetic(replacements, to: exact, protecting: [])
    }

    /// First pass: exact match with cases.
    ///
    /// The literal rise of the previous body is a mutating and general accumulator, therefore
    /// replacements can be layered (a later rule rewrites what generated
    /// earlier). This behavior is fixed by tests and cannot be changed.
    static func applyExact(
        _ replacements: [DictionaryReplacement],
        to text: String
    ) -> String {
        guard !replacements.isEmpty, !text.isEmpty else { return text }

        var result = text
        // Long options first: otherwise "pull" will be replaced inside "pull request".
        for replacement in replacements.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            let spoken = replacement.spoken.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty else { continue }
            result = replaceWholeWords(
                of: spoken,
                with: replacement.written,
                inflected: replacement.inflects,
                in: result
            )
        }
        return result
    }

    /// Second pass: phonetic selection outside of protected spans.
    ///
    /// An empty set of spans literally goes to the previous path, and not “to a new one”
    /// path with an empty filter." The matcher is greedy, its behavior is emergent, and
    /// Identity should rest on construction, not reasoning.
    static func applyPhonetic(
        _ replacements: [DictionaryReplacement],
        to text: String,
        protecting spans: [ProtectedSpan]
    ) -> String {
        guard !replacements.isEmpty, !text.isEmpty else { return text }
        guard !spans.isEmpty else { return PhoneticMatching.apply(replacements, to: text) }
        return PhoneticMatching.apply(replacements, to: text, protecting: spans)
    }

    static func replaceWholeWords(
        of needle: String,
        with replacement: String,
        inflected: Bool,
        in text: String
    ) -> String {
        let expression = pattern(for: needle, inflected: inflected)
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Case endings that Russian adds to a borrowed word.
    ///
    /// The list is closed and short on purpose: these are not “similar words”, but exactly those
    /// tails, due to which an exact match never works.
    private static let endings = [
        "\u{0430}\u{043C}\u{0438}", "\u{044F}\u{043C}\u{0438}", "\u{043E}\u{0439}", "\u{0435}\u{0439}", "\u{043E}\u{043C}", "\u{0435}\u{043C}", "\u{043E}\u{0432}", "\u{0435}\u{0432}", "\u{0430}\u{043C}", "\u{044F}\u{043C}", "\u{0430}\u{0445}", "\u{044F}\u{0445}",
        "\u{0430}", "\u{0435}", "\u{0438}", "\u{044B}", "\u{0443}", "\u{044E}", "\u{044F}",
    ]

    /// Expression for finding a replacement in the text.
    ///
    /// The Russian word is inflected, but the Latin term is not. Man says
    /// “before release”, “in python”, “without downtime” and waits for “before release”,
    /// “in Python”, “without downtime” - replacement by exact match is not here
    /// never works. Therefore, case replacements are allowed in Cyrillic substitutions
    /// ending at the end.
    ///
    /// This does not apply to Latin substitutions: English terms in Russian speech do not
    /// bow, and the extra tail there would mean a different word.
    static func pattern(for needle: String, inflected: Bool = true) -> String {
        let leading = "(?<![\\p{L}\\p{N}])"
        let trailing = "(?![\\p{L}\\p{N}])"

        let words = needle.split(separator: " ").map(String.init)
        guard let last = words.last, inflected, isInflectable(needle) else {
            return leading + NSRegularExpression.escapedPattern(for: needle) + trailing
        }

        // For words ending in “th”, the ending replaces the “th” itself: deployment → deployment, deployment.
        // Therefore, we cut it off and add it back to the list of tails - otherwise
        // the word itself would cease to coincide with itself.
        let hasShortI = last.hasSuffix("\u{0439}")
        let stem = hasShortI ? String(last.dropLast()) : last
        let tails = (hasShortI ? ["\u{0439}"] + Self.endings : Self.endings)
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        let head = words.dropLast()
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "\\s+")
        let prefix = head.isEmpty ? "" : head + "\\s+"

        return leading + prefix + NSRegularExpression.escapedPattern(for: stem)
            + "(?:" + tails + ")?" + trailing
    }

    /// Is it worth waiting for the case ending?
    ///
    /// Only for Cyrillic and only from four letters: short words have a tail
    /// is too often the beginning of another word.
    ///
    /// Words with a vowel (“figma” → “figme”) do not fall here, and this is deliberate.
    /// To catch them, you would have to cut off the final vowel - and then
    /// “centry” will become the stem “center”, and “in the center of the city” will become
    /// "in Sentry City". We take care of exactly this case with a separate test. Price -
    /// such a replacement is caught only in the form in which it is written; in
    /// the supplied set ends with six entries per vowel: “review”,
    /// “code review”, “cat review”, “sentry”, “centry”, “linty”.
    private static func isInflectable(_ needle: String) -> Bool {
        guard let last = needle.split(separator: " ").last, last.count >= 4 else { return false }
        return needle.allSatisfy { character in
            // The hyphen is part of the term: the model writes “type script” in one word,
            // and only his tail bends anyway.
            character == " " || character == "-"
                || character.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
        }
    }
}
