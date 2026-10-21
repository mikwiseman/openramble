import Foundation

/// Command spoken at the end of the dictation.
///
/// “Send” at the end of the phrase is not text, but an action: the user expects that
/// the message will go away, and not that the word will appear in the input field.
public enum TrailingCommand: String, Sendable, Equatable, CaseIterable {
    case pressReturn
    case newLine

    /// Pronunciation options in Russian and English.
    var phrases: [String] {
        switch self {
        case .pressReturn:
            return ["\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}", "\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{0442}\u{044C}", "\u{044D}\u{043D}\u{0442}\u{0435}\u{0440}", "send it", "press enter"]
        case .newLine:
            return ["\u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}", "\u{0441} \u{043D}\u{043E}\u{0432}\u{043E}\u{0439} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}", "new line"]
        }
    }
}

/// Parsing the final command.
public enum TrailingCommandParser {
    public struct Result: Sendable, Equatable {
        public let text: String
        public let command: TrailingCommand?
    }

    /// Separate the command from the text.
    ///
    /// Only the very tail of the phrase is parsed: the word “send” in the middle
    /// sentences are an ordinary word, not a command.
    public static func parse(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(text: trimmed, command: nil) }

        // We compare the tail without the final punctuation: “...send.” - the same team.
        let strippedTail = trimmed.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))

        for command in TrailingCommand.allCases {
            for phrase in command.phrases where strippedTail.hasSuffix(phrase) {
                // The command must be a separate word, not the tail of another.
                // Any whitespace sets it apart: after a long pause in prose the
                // paragraph mark has already become a blank line.
                let cutoff = strippedTail.index(strippedTail.endIndex, offsetBy: -phrase.count)
                if cutoff > strippedTail.startIndex {
                    let preceding = strippedTail[strippedTail.index(before: cutoff)]
                    guard preceding.isWhitespace else { continue }
                }

                let withoutCommand = stripSuffix(phrase, from: trimmed)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))

                // A command spoken alone is just a word.
                //
                // There is no text left to insert, and you have to press Return in someone else's window
                // one guess is impossible: the sent message is not recalled.
                // Previously, such a dictation would go nowhere - empty text
                // canceled both the insertion and the click itself.
                guard !withoutCommand.isEmpty else { return Result(text: trimmed, command: nil) }

                return Result(text: withoutCommand, command: command)
            }
        }
        return Result(text: trimmed, command: nil)
    }

    private static func stripSuffix(_ phrase: String, from text: String) -> String {
        // We search in the string itself, and not in its copy reduced to lower case.
        // The cast has its own length: the Turkish "İ" turns into two characters, and
        // positions found in the copy cut the original in the wrong place - until it falls
        // when going beyond line boundaries.
        guard let range = text.range(of: phrase, options: [.backwards, .caseInsensitive]) else {
            return text
        }
        return String(text[text.startIndex..<range.lowerBound])
    }
}

/// Anything that can turn recognized text into text to insert.
///
/// Exists so the application can choose its implementation while this package
/// keeps its own. That distinction matters more than it looks: the conformance
/// fixtures are recordings of the Swift pipeline below, and if this package
/// delegated to the shared core instead, the fixtures would be recordings of
/// the thing they are meant to check. The two implementations have to stay
/// genuinely independent for the comparison to mean anything.
public protocol TextProcessing: Sendable {
    func run(_ recognized: String) -> TextPipeline.Run
}

/// The full path from the recognized text to what the user sees.
///
/// **Table of stages.** The order is fixed and checked by golden tests for
/// each border (`TextPipelineContractTests`):
///
/// | # | Stage | What does |
/// |---|---|---|
/// | 1 | command parser | separates the final command - before all replacements, otherwise the dictionary will touch it |
/// | 2 | dictionary: exact pass | literal dictionary entries, with cases |
/// | 3 | span detection | first calculation of protected pieces |
/// | 4 | dictionary: phonetic selection | guesses - only outside of spans |
/// | 5 | Clean Verbatim | deletes hesitations, stutters, spoken corrections - never rewords; spans are atomic |
/// | 6 | *(snippets)* | **reserved**, no stage in this wave |
/// | 7 | typography-fold | 12 characters, no spans |
/// | 8 | polisher | spaces, punctuation, first letter - outside of spans |
/// | 9 | materialize `.newLine` | strictly last: polisher trims `\n` |
///
/// Stage 6 is reserved as a **comment, not code**: a stub that does nothing -
/// a ceremony, not a contract. When it appears it stands between 5 and 7, and
/// the span gate will pick it up itself.
///
/// The key to the entire protection model: **exact replacement comes before spans at all
/// exist**. This is the rule “the clear will of a person is higher than the protection of span” -
/// There is no need to write a separate precedent rule, order is the rule.
public struct TextPipeline: Sendable, TextProcessing {
    public struct Output: Sendable, Equatable {
        /// Text ready to be inserted.
        public let text: String
        /// What to click after inserting, if the user asked for it.
        ///
        /// The line break does not appear here: it is already in the text. Pressing it does not
        /// do - Return in someone else's window sends a message rather than transferring it
        /// string.
        public let command: TrailingCommand?

        /// Public so an implementation outside this package can produce one.
        /// The shared core does; see `TextProcessing`.
        public init(text: String, command: TrailingCommand?) {
            self.text = text
            self.command = command
        }
    }

    /// The result of the run along with the origin of the text.
    public struct Run: Sendable, Equatable {
        public let output: Output
        public let provenance: PipelineProvenance

        public init(output: Output, provenance: PipelineProvenance) {
            self.output = output
            self.provenance = provenance
        }
    }

    private let replacements: [DictionaryReplacement]
    private let allowPressReturnCommand: Bool
    /// Phonetic selection switch - exists for the purpose of measuring “is it necessary
    /// it’s generally on top of the acoustic prompt” (WAI_EVAL_PIPELINE=exact).
    private let phoneticMatching: Bool
    /// "Scratch that" removes a sentence when dictating; a meeting transcript
    /// keeps what was said. See `CleanVerbatim`.
    private let spokenCorrections: Bool
    /// Where the text is going. Prose apps get paragraph breaks; verbatim apps
    /// (terminals, editors, anything unknown) never receive a newline they did
    /// not ask for. See `PromptModePolicy`.
    private let mode: PromptMode

    public init(
        replacements: [DictionaryReplacement] = [],
        allowPressReturnCommand: Bool = false,
        phoneticMatching: Bool = true,
        spokenCorrections: Bool = true,
        mode: PromptMode = .verbatim
    ) {
        self.replacements = replacements
        self.allowPressReturnCommand = allowPressReturnCommand
        self.phoneticMatching = phoneticMatching
        self.spokenCorrections = spokenCorrections
        self.mode = mode
    }

    /// Whether `text` closes with a full stop, question mark, exclamation or
    /// ellipsis — what makes a trailing command its own sentence.
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return CleanVerbatim.sentenceEnding.contains(last)
    }

    /// Stages 2-8: everything between the command parser and the newline.
    private func transform(_ text: String) -> (afterDictionary: String, polished: String) {
        // Stage 2: exact pass - before spans exist.
        let exact = DictionaryReplacements.applyExact(replacements, to: text)
        // Stage 3: the first calculation of spans is based on the result of exact replacements.
        let spansAfterExact = ProtectedSpanDetector.detect(in: exact)
        // Stage 4: phonetic selection outside of spans.
        let afterDictionary = phoneticMatching
            ? DictionaryReplacements.applyPhonetic(replacements, to: exact, protecting: spansAfterExact)
            : exact

        // Stage 5: Clean Verbatim - only deletes, so it cannot write a word
        // that was not said. `afterDictionary` stays the checkpoint before it.
        let cleaned = CleanVerbatim.clean(
            afterDictionary,
            spokenCorrections: spokenCorrections,
            protectedWords: CleanVerbatim.protectedWords(from: replacements),
            mode: mode
        )

        // Stage 7: collapsing typography outside of spans.
        let folded = TypographyFold.fold(
            cleaned,
            protecting: ProtectedSpanDetector.detect(in: cleaned)
        )
        // Stage 8: polisher (recalculates spans itself).
        return (afterDictionary, TranscriptPolisher.polish(folded))
    }

    public func process(_ recognized: String) -> Output {
        run(recognized).output
    }

    /// Same as `process`, but with a record of the origin of the text.
    ///
    /// Origin is built **unconditionally** - it does not depend on any
    /// custom toggle switch. The only path is the same: `process`
    /// calls `run` and throws away the entry, so “branches without provenance”
    /// does not exist in the product.
    public func run(_ recognized: String) -> Run {
        // Stage 0: a paragraph mark (`ParagraphBreaks`) is a blank line where
        // prose is going and a plain space everywhere else.
        let recognized = recognized.replacingOccurrences(
            of: String(ParagraphBreaks.marker),
            with: mode == .prose ? "\n\n" : " "
        )
        var parsed = TrailingCommandParser.parse(recognized)
        // Return is pressed only where the caller allows it (terminals) and
        // only for a command said as its own final sentence: "…first. Send it."
        // One false trigger submits irreversibly, so "…and then we send it"
        // mid-thought stays words.
        var refusedOnlyAsMidSentence = false
        if parsed.command == .pressReturn,
           !allowPressReturnCommand || !Self.endsSentence(parsed.text) {
            refusedOnlyAsMidSentence = allowPressReturnCommand
            parsed = TrailingCommandParser.Result(text: recognized, command: nil)
        }

        var stages = transform(parsed.text)
        if stages.polished.isEmpty, parsed.command != nil {
            // A command with nothing left to act on is just words, as when it
            // is spoken alone — never an empty insert that reads as "nothing
            // was recognized" with the command silently gone.
            parsed = TrailingCommandParser.Result(text: recognized, command: nil)
            stages = transform(recognized)
        }
        // A hesitation or stutter right before "Send it." hides it from the
        // parser above ("…first. Um, send it.") and is gone once the text is
        // clean, so Return is decided once more on the cleaned text, by the
        // same rules: allowed here, and "Send it." as its own final sentence.
        // Only when "Send it." was the last thing said: words after it that
        // cleanup removed ("Stop, scratch that.") were taking the send back,
        // and a dictionary entry that writes "send it" was never the command.
        if refusedOnlyAsMidSentence, parsed.command == nil {
            let cleaned = TrailingCommandParser.parse(stages.polished)
            if cleaned.command == .pressReturn, Self.endsSentence(cleaned.text) {
                parsed = cleaned
                stages.polished = cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let afterDictionary = stages.afterDictionary
        let polished = stages.polished

        // Stage 9: materialization of the “new line” - strictly the last one, otherwise
        // the polisher will cut off the transfer with its trim.
        let output: Output
        if parsed.command == .newLine, !polished.isEmpty {
            // "New line" is a command that cannot be executed by pressing: Return
            // would send a message. Therefore, the transfer goes directly into the text - it
            // inserted along with it. Previously, words were cut out from the text, and in return
            // nothing happened: the entire team disappeared.
            output = Output(text: polished + "\n", command: nil)
        } else {
            output = Output(text: polished, command: parsed.command)
        }

        return Run(
            output: output,
            provenance: PipelineProvenance(
                afterDictionary: afterDictionary,
                finalText: output.text,
                spans: ProtectedSpanDetector.detect(in: output.text)
            )
        )
    }
}
