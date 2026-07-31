import Foundation

/// Команда, сказанная в конце диктовки.
///
/// «Отправь» в конце фразы — это не текст, а действие: пользователь ждёт, что
/// сообщение уйдёт, а не что слово окажется в поле ввода.
public enum TrailingCommand: String, Sendable, Equatable, CaseIterable {
    case pressReturn
    case newLine

    /// Варианты произношения на русском и английском.
    var phrases: [String] {
        switch self {
        case .pressReturn:
            return ["отправь", "отправить", "энтер", "send it", "press enter"]
        case .newLine:
            return ["новая строка", "с новой строки", "new line"]
        }
    }
}

/// Разбор завершающей команды.
public enum TrailingCommandParser {
    public struct Result: Sendable, Equatable {
        public let text: String
        public let command: TrailingCommand?
    }

    /// Отделить команду от текста.
    ///
    /// Разбирается только самый хвост фразы: слово «отправь» в середине
    /// предложения — обычное слово, а не команда.
    public static func parse(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(text: trimmed, command: nil) }

        // Хвост сравниваем без финальной пунктуации: «…отправь.» — та же команда.
        let strippedTail = trimmed.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))

        for command in TrailingCommand.allCases {
            for phrase in command.phrases where strippedTail.hasSuffix(phrase) {
                // Команда должна быть отдельным словом, а не хвостом другого.
                let cutoff = strippedTail.index(strippedTail.endIndex, offsetBy: -phrase.count)
                if cutoff > strippedTail.startIndex {
                    let preceding = strippedTail[strippedTail.index(before: cutoff)]
                    guard preceding == " " else { continue }
                }

                let withoutCommand = stripSuffix(phrase, from: trimmed)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))

                // Команда, сказанная в одиночку, — это просто слово.
                //
                // Текста для вставки не осталось, а нажимать Return в чужом окне
                // по одной догадке нельзя: отправленное сообщение не отзывается.
                // Раньше такая диктовка проваливалась в никуда — пустой текст
                // отменял и вставку, и само нажатие.
                guard !withoutCommand.isEmpty else { return Result(text: trimmed, command: nil) }

                return Result(text: withoutCommand, command: command)
            }
        }
        return Result(text: trimmed, command: nil)
    }

    private static func stripSuffix(_ phrase: String, from text: String) -> String {
        // Ищем в самой строке, а не в её копии, приведённой к нижнему регистру.
        // У приведения своя длина: турецкая «İ» превращается в два символа, и
        // позиции, найденные в копии, режут оригинал не там — вплоть до падения
        // на выходе за границы строки.
        guard let range = text.range(of: phrase, options: [.backwards, .caseInsensitive]) else {
            return text
        }
        return String(text[text.startIndex..<range.lowerBound])
    }
}

/// Полный путь от распознанного текста до того, что увидит пользователь.
///
/// Порядок шагов важен и зафиксирован:
/// 1. Отделить завершающую команду — до всех замен, иначе словарь может её задеть.
/// 2. Применить пользовательский словарь.
/// 3. Причесать пробелы, пунктуацию и первую букву.
public struct TextPipeline: Sendable {
    public struct Output: Sendable, Equatable {
        /// Текст, готовый к вставке.
        public let text: String
        /// Что нажать после вставки, если пользователь об этом попросил.
        public let command: TrailingCommand?
    }

    private let replacements: [DictionaryReplacement]

    public init(replacements: [DictionaryReplacement] = []) {
        self.replacements = replacements
    }

    public func process(_ recognized: String) -> Output {
        let parsed = TrailingCommandParser.parse(recognized)
        let replaced = DictionaryReplacements.apply(replacements, to: parsed.text)
        let polished = TranscriptPolisher.polish(replaced)
        return Output(text: polished, command: parsed.command)
    }
}
