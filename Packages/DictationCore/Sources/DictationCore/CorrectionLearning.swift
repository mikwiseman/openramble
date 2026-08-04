import Foundation

/// Обучение словаря по правке последней диктовки.
///
/// Поверхность правки — собственное окно приложения: мы не читаем чужие
/// приложения и не следим за клавиатурой, поэтому единственный честный сигнал —
/// текст, который человек поправил у нас сам. Пословный diff превращает правку
/// в кандидатов на замену.
///
/// Фильтр консервативен намеренно. Учится только пара, где правая сторона
/// похожа на термин: содержит латиницу либо смешанный регистр. Всё остальное —
/// скорее правка речи («быстро» → «быстрее»), и выучить её значило бы молча
/// подменять слова человека в следующих диктовках. Правило то же, что у
/// фильтра «обычных слов» в индустрии, но проверяемое и локальное.
public enum CorrectionLearning {
    /// Предложить замены по правке. Ничего не сохраняет — только предлагает.
    public static func propose(
        original: String,
        edited: String,
        existing: [DictionaryReplacement] = []
    ) -> [DictionaryReplacement] {
        let originalWords = words(from: original)
        let editedWords = words(from: edited)
        guard !originalWords.isEmpty, !editedWords.isEmpty else { return [] }

        let known = Set(existing.map { $0.spoken.lowercased() })
        var proposals: [DictionaryReplacement] = []

        for pair in substitutions(from: originalWords, to: editedWords) {
            let spoken = pair.original.joined(separator: " ")
            let written = pair.edited.joined(separator: " ")
            guard spoken.lowercased() != written.lowercased() || spoken != written else {
                continue
            }
            guard looksLikeTerm(written) else { continue }
            guard !known.contains(spoken.lowercased()) else { continue }
            // Термины из правки латиницей не склоняются — как и в стартовом
            // наборе: склоняемая основа выдумывала бы совпадения.
            proposals.append(DictionaryReplacement(spoken: spoken, written: written, inflects: false))
        }
        return proposals
    }

    // MARK: - Diff

    private struct Substitution {
        let original: [String]
        let edited: [String]
    }

    /// Пары «заменённый кусок → чем заменили» по LCS-выравниванию слов.
    ///
    /// Вставки и удаления замен не порождают: замена — это когда с обеих
    /// сторон что-то есть. Куски длиннее трёх слов отбрасываются: это уже
    /// переписанное предложение, а не правка термина.
    private static func substitutions(
        from original: [String],
        to edited: [String]
    ) -> [Substitution] {
        let table = lcsTable(original.map { $0.lowercased() }, edited.map { $0.lowercased() })
        var result: [Substitution] = []
        var i = original.count
        var j = edited.count
        var pendingOriginal: [String] = []
        var pendingEdited: [String] = []

        func flush() {
            defer {
                pendingOriginal = []
                pendingEdited = []
            }
            guard !pendingOriginal.isEmpty, !pendingEdited.isEmpty else { return }
            guard pendingOriginal.count <= 3, pendingEdited.count <= 3 else { return }
            result.append(
                Substitution(
                    original: pendingOriginal.reversed(),
                    edited: pendingEdited.reversed()
                )
            )
        }

        while i > 0 || j > 0 {
            if i > 0, j > 0, original[i - 1].lowercased() == edited[j - 1].lowercased(),
               original[i - 1] == edited[j - 1] {
                flush()
                i -= 1
                j -= 1
            } else if i > 0, j > 0,
                      original[i - 1].lowercased() == edited[j - 1].lowercased() {
                // Слово то же, но регистр другой — это тоже правка.
                pendingOriginal.append(original[i - 1])
                pendingEdited.append(edited[j - 1])
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || table[i][j - 1] >= table[i - 1][j] {
                pendingEdited.append(edited[j - 1])
                j -= 1
            } else {
                pendingOriginal.append(original[i - 1])
                i -= 1
            }
        }
        flush()
        return result.reversed()
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...max(1, a.count) where !a.isEmpty {
            for j in 1...max(1, b.count) where !b.isEmpty {
                table[i][j] = a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table
    }

    // MARK: - Фильтры

    private static func words(from text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
    }

    /// Похоже ли написанное на термин, ради которого заводят словарь.
    private static func looksLikeTerm(_ written: String) -> Bool {
        let hasLatin = written.contains { $0.isLetter && $0.isASCII }
        guard hasLatin else { return false }
        return true
    }
}
