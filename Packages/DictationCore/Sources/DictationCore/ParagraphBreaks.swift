import Foundation

/// Where a long pause after a sentence becomes a paragraph.
///
/// The model reports word timings with the silence folded in: a pause after a
/// sentence either stretches the last word ("green." lasting two seconds) or
/// leaves a gap before the next one. So the pause after a word is estimated as
/// the time from its start to the next word's start, minus how long the word
/// itself takes to say. Calibrated on the shipping model with two voices and
/// silences from 300 ms to 3 s: an estimate of one second matches about a
/// second and a half of real silence, which reads as a new paragraph, while
/// the ordinary pause between sentences stays well under it.
///
/// Only a word that ends a sentence can end a paragraph. The text is marked
/// with U+2029 PARAGRAPH SEPARATOR, which the text pipeline turns into a blank
/// line in prose apps and a plain space everywhere else — the policy does not
/// need to know where the words are going.
///
/// When the words cannot be matched to the text one for one, nothing is
/// guessed: the text goes on unbroken.
public enum ParagraphBreaks {
    public static let marker: Character = "\u{2029}"

    /// Estimated silence beyond the word itself that starts a new paragraph.
    static let minimumPause: TimeInterval = 1.0

    public static func mark(_ text: String, words: [ASRResult.Word]) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1, tokens.count == words.count,
              zip(tokens, words).allSatisfy({ $0 == $1.text })
        else { return text }

        var result = tokens[0]
        var changed = false
        for index in 1..<tokens.count {
            let previous = words[index - 1]
            let pause = words[index].start - previous.start - spokenLength(of: previous.text)
            if endsSentence(tokens[index - 1]), pause >= minimumPause {
                result.append(marker)
                changed = true
            } else {
                result.append(" ")
            }
            result += tokens[index]
        }
        return changed ? result : text
    }

    /// Text already shaped for one app, made fit for the app it reaches
    /// instead ("Insert Last Dictation" goes to whatever is in front). A
    /// verbatim app never receives a paragraph break it did not ask for: each
    /// becomes the space the pipeline would have put there. A line break the
    /// person asked for with "New line." stays.
    public static func fit(_ text: String, to mode: PromptMode) -> String {
        mode == .prose ? text : text.replacingOccurrences(of: "\n\n", with: " ")
    }

    /// How long a word takes to say, generously: a quarter second plus 70 ms
    /// a letter.
    static func spokenLength(of word: String) -> TimeInterval {
        0.25 + 0.07 * Double(word.filter(\.isLetter).count)
    }

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return CleanVerbatim.sentenceEnding.contains(last)
    }
}
