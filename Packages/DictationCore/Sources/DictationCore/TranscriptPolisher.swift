import Foundation

/// Детерминированная доводка распознанного текста.
///
/// Никаких языковых моделей: только то, что можно проверить и предсказать.
/// Правки здесь не меняют смысл — они убирают следы того, что текст пришёл из
/// распознавания, а не был набран руками.
///
/// Осознанно НЕ делаем: не разворачиваем числительные («двадцать пять» → «25»)
/// — в русском это упирается в склонения и падежи и ломает больше, чем чинит.
public enum TranscriptPolisher {
    /// Привести распознанный текст в вид, пригодный для вставки.
    public static func polish(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        result = collapseWhitespace(in: result)
        result = fixSpacingAroundPunctuation(in: result)
        result = capitalizeFirstLetter(of: result)
        return result
    }

    /// Схлопнуть повторяющиеся пробелы, сохранив переводы строк.
    static func collapseWhitespace(in text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    /// Убрать пробел перед знаком препинания и поставить после него там,
    /// где его точно не хватает.
    ///
    /// Вставка пробела намеренно осторожная. Модель сама превращает
    /// «три и четырнадцать сотых» в «3.14», а точка встречается в версиях
    /// («2.0.1»), доменах («wai.computer») и сокращениях («т.д.»); двоеточие —
    /// в ссылках («https://») и времени («12:30»). Раньше пробел ставился после
    /// любой точки, и всё перечисленное разваливалось — проверено на настоящем
    /// выходе модели.
    ///
    /// Поэтому у точки и двоеточия условие осталось прежним: пробел ставится
    /// только перед заглавной буквой, то есть когда началось новое предложение.
    static func fixSpacingAroundPunctuation(in text: String) -> String {
        let closing: Set<Character> = [",", ".", "!", "?", ";", ":", "…"]

        /// Знаки, после которых пробел нужен всегда, если дальше буква.
        ///
        /// «первое,второе» модель отдаёт постоянно, и заглавной там не бывает —
        /// с условием «только перед заглавной» перечисление оставалось
        /// слипшимся. У этих знаков нет ни одного написания, где буква стоит
        /// вплотную по делу: единственное такое место у запятой — десятичная
        /// дробь, а там дальше идёт цифра, и правило её не трогает.
        let alwaysSeparating: Set<Character> = [",", "!", "?", ";", "…"]

        var result = ""
        result.reserveCapacity(text.count)

        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]

            if closing.contains(character) {
                // Пробел перед знаком препинания — артефакт распознавания.
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

    /// Заглавная первая буква — распознавание нередко отдаёт строчную.
    static func capitalizeFirstLetter(of text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
