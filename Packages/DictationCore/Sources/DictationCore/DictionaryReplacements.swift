import Foundation

/// Пользовательская замена: как распознаётся → как должно быть написано.
///
/// Ради этого словарь и нужен: модель не знает названий, которыми пользователь
/// живёт каждый день, и стабильно пишет «сентри» вместо «Sentry».
public struct DictionaryReplacement: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Что услышала модель.
    public var spoken: String
    /// Что должно оказаться в тексте.
    public var written: String

    public init(id: UUID = UUID(), spoken: String, written: String) {
        self.id = id
        self.spoken = spoken
        self.written = written
    }
}

/// Применение словаря к распознанному тексту.
public enum DictionaryReplacements {
    /// Заменить все вхождения по границам слов.
    ///
    /// Границы обязательны: без них замена «код» → «code» превратила бы
    /// «кодировка» в «codeировка». Регистр входа игнорируется, потому что
    /// распознавание не гарантирует его стабильность.
    public static func apply(_ replacements: [DictionaryReplacement], to text: String) -> String {
        guard !replacements.isEmpty, !text.isEmpty else { return text }

        var result = text
        // Длинные варианты первыми: иначе «pull» подменится внутри «pull request».
        for replacement in replacements.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            let spoken = replacement.spoken.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty else { continue }
            result = replaceWholeWords(of: spoken, with: replacement.written, in: result)
        }
        return result
    }

    static func replaceWholeWords(of needle: String, with replacement: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern(for: needle), options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Падежные окончания, которые русский добавляет к заимствованному слову.
    ///
    /// Список закрытый и короткий намеренно: это не «похожие слова», а ровно те
    /// хвосты, из-за которых точное совпадение не срабатывает никогда.
    private static let endings = [
        "ами", "ями", "ой", "ей", "ом", "ем", "ов", "ев", "ам", "ям", "ах", "ях",
        "а", "е", "и", "ы", "у", "ю", "я",
    ]

    /// Выражение для поиска замены в тексте.
    ///
    /// Русское слово склоняется, а латинский термин — нет. Человек говорит
    /// «перед релизом», «на питоне», «без даунтайма» и ждёт «перед release»,
    /// «на Python», «без downtime» — замена по точному совпадению здесь не
    /// срабатывает ни разу. Поэтому у кириллических замен допускается падежное
    /// окончание в конце.
    ///
    /// Латинских замен это не касается: английские термины в русской речи не
    /// склоняются, а лишний хвост там означал бы другое слово.
    static func pattern(for needle: String) -> String {
        let leading = "(?<![\\p{L}\\p{N}])"
        let trailing = "(?![\\p{L}\\p{N}])"

        let words = needle.split(separator: " ").map(String.init)
        guard let last = words.last, isInflectable(needle) else {
            return leading + NSRegularExpression.escapedPattern(for: needle) + trailing
        }

        // У слов на «-й» окончание заменяет саму «й»: деплой → деплоя, деплою.
        // Поэтому её отрезаем, а в список хвостов добавляем обратно — иначе
        // само слово перестало бы совпадать с собой.
        let hasShortI = last.hasSuffix("й")
        let stem = hasShortI ? String(last.dropLast()) : last
        let tails = (hasShortI ? ["й"] + Self.endings : Self.endings)
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        let head = words.dropLast()
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "\\s+")
        let prefix = head.isEmpty ? "" : head + "\\s+"

        return leading + prefix + NSRegularExpression.escapedPattern(for: stem)
            + "(?:" + tails + ")?" + trailing
    }

    /// Стоит ли ждать падежного окончания.
    ///
    /// Только для кириллицы и только от четырёх букв: у коротких слов хвост
    /// слишком часто оказывается началом другого слова.
    ///
    /// Слова на гласную («фигма» → «фигме») сюда не попадают, и это осознанно.
    /// Чтобы их поймать, пришлось бы отрезать конечную гласную — а тогда
    /// «центри» превратится в основу «центр», и «в центре города» станет
    /// «в Sentry города». Ровно этот случай мы бережём отдельным тестом. Цена —
    /// пользовательскую замену на гласную приходится заводить в двух формах;
    /// в поставляемом наборе таких слов нет.
    private static func isInflectable(_ needle: String) -> Bool {
        guard let last = needle.split(separator: " ").last, last.count >= 4 else { return false }
        return needle.allSatisfy { character in
            // Дефис — часть термина: модель пишет «тайп-скрипт» одним словом,
            // и склоняется у него всё равно только хвост.
            character == " " || character == "-"
                || character.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
        }
    }
}
