import DictationCore
import Foundation
import LocalASR

/// Одна запись корпуса: файл и то, что в нём на самом деле сказано.
struct EvalItem: Decodable {
    let file: String
    let reference: String
    let tags: [String]
}

/// Итог по одной записи.
struct EvalOutcome {
    let item: EvalItem
    let report: ScoreReport
    let result: ASRResult
    let wallClock: TimeInterval
    let peakMemory: Int64
}

enum Evaluation {
    static func loadManifest(at path: String) throws -> [EvalItem] {
        // Через `LocalFile`, а не `Data(contentsOf:)`: тот принимает и http-адрес
        // и молча ушёл бы в сеть, из-за чего проверка сетевой поверхности
        // запрещает его во всём проекте.
        let data = try LocalFile.read(URL(fileURLWithPath: path))
        return try JSONDecoder().decode([EvalItem].self, from: data)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    static func describe(_ outcome: EvalOutcome, showDifferences: Bool) -> String {
        let report = outcome.report
        var lines: [String] = []
        lines.append("\n=== \(URL(fileURLWithPath: outcome.item.file).lastPathComponent) [\(outcome.item.tags.joined(separator: ","))] ===")
        lines.append("сырой ответ: \(outcome.result.text)")
        lines.append("эталон:   \(report.reference.text)")
        lines.append("получено: \(report.hypothesis.text)")
        lines.append(
            String(
                format: "WER %@ (з %d п %d в %d из %d)  CER %@  WER+пункт %@  знаки %d/%d",
                percent(report.words.rate),
                report.words.substitutions,
                report.words.deletions,
                report.words.insertions,
                report.words.referenceLength,
                percent(report.characterErrorRate),
                percent(report.wordsWithPunctuation.rate),
                report.punctuation.correct,
                report.punctuation.referenceLength
            )
        )
        let realtime = outcome.wallClock > 0 ? outcome.result.audioDuration / outcome.wallClock : 0
        lines.append(
            String(
                format: "аудио %.1f с, распознавание %.2f с — %.0f× реального времени, слов с таймингами %d",
                outcome.result.audioDuration,
                outcome.wallClock,
                realtime,
                outcome.result.words.count
            )
        )
        if showDifferences, !report.differences.isEmpty {
            let shown = report.differences.prefix(25).map(\.description).joined(separator: "; ")
            let tail = report.differences.count > 25 ? " … всего \(report.differences.count)" : ""
            lines.append("расхождения: \(shown)\(tail)")
        }
        return lines.joined(separator: "\n")
    }

    /// Сводка по группам: сравнение сценариев между собой — единственный вывод,
    /// который синтез вообще позволяет сделать.
    static func summary(_ outcomes: [EvalOutcome]) -> String {
        var byTag: [String: [EvalOutcome]] = [:]
        for outcome in outcomes {
            for tag in outcome.item.tags {
                byTag[tag, default: []].append(outcome)
            }
        }

        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }

        var lines: [String] = ["\n=== Сводка по группам ==="]
        lines.append("\(pad("группа", 16)) записей   слов  WER     CER     WER+пункт знаки")
        for tag in byTag.keys.sorted() {
            let group = byTag[tag]!
            let words = group.reduce(into: ScoreReport.Counts()) { total, outcome in
                total.substitutions += outcome.report.words.substitutions
                total.deletions += outcome.report.words.deletions
                total.insertions += outcome.report.words.insertions
                total.correct += outcome.report.words.correct
            }
            let tokens = group.reduce(into: ScoreReport.Counts()) { total, outcome in
                total.substitutions += outcome.report.wordsWithPunctuation.substitutions
                total.deletions += outcome.report.wordsWithPunctuation.deletions
                total.insertions += outcome.report.wordsWithPunctuation.insertions
                total.correct += outcome.report.wordsWithPunctuation.correct
            }
            let marks = group.reduce(into: ScoreReport.Counts()) { total, outcome in
                total.substitutions += outcome.report.punctuation.substitutions
                total.deletions += outcome.report.punctuation.deletions
                total.insertions += outcome.report.punctuation.insertions
                total.correct += outcome.report.punctuation.correct
            }
            // CER взвешен по длине эталона, иначе короткая запись весила бы
            // столько же, сколько получасовая.
            let characters = group.reduce(into: (errors: 0.0, total: 0.0)) { totals, outcome in
                let length = Double(outcome.report.reference.characters.count)
                totals.errors += outcome.report.characterErrorRate * length
                totals.total += length
            }
            let cer = characters.total > 0 ? characters.errors / characters.total : 0

            lines.append(
                pad(tag, 16)
                    + String(format: " %7d %6d  ", group.count, words.referenceLength)
                    + pad(percent(words.rate), 8)
                    + pad(percent(cer), 8)
                    + pad(percent(tokens.rate), 10)
                    + "\(marks.correct)/\(marks.referenceLength)"
            )
        }
        return lines.joined(separator: "\n")
    }
}
