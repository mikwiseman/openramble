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
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: needle) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
