import DictationCore
import Foundation
import LocalASR

/// One corpus entry: the file and what it actually says.
struct EvalItem: Decodable {
    let file: String
    let reference: String
    let tags: [String]
}

/// Total for one record.
struct EvalOutcome {
    let item: EvalItem
    let report: ScoreReport
    let result: ASRResult
    let wallClock: TimeInterval
    let peakMemory: Int64
}

enum Evaluation {
    static func loadManifest(at path: String) throws -> [EvalItem] {
        // Via `LocalFile`, not `Data(contentsOf:)`: it also accepts the http address
        // and would silently go online, causing the network surface to be checked
        // disables it in the entire project.
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
        lines.append("raw response: \(outcome.result.text)")
        lines.append("reference: \(report.reference.text)")
        lines.append("received: \(report.hypothesis.text)")
        lines.append(
            String(
                format: "WER %@ (from %d p %d to %d from %d) CER %@ WER+item %@ characters %d/%d",
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
                format: "audio %.1f s, recognition %.2f s - %.0f× real time, words with timings %d",
                outcome.result.audioDuration,
                outcome.wallClock,
                realtime,
                outcome.result.words.count
            )
        )
        if showDifferences, !report.differences.isEmpty {
            let shown = report.differences.prefix(25).map(\.description).joined(separator: "; ")
            let tail = report.differences.count > 25 ? "...total \(report.differences.count)" : ""
            lines.append("divergences: \(shown)\(tail)")
        }
        return lines.joined(separator: "\n")
    }

    /// Group summary: comparison of scenarios with each other is the only conclusion,
    /// which synthesis generally allows you to do.
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

        var lines: [String] = ["\n=== Group summary ==="]
        lines.append("\(pad("group", 16)) entries of words WER CER WER+item signs")
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
            // CER is weighted by the length of the reference, otherwise the short record would weigh
            // as much as half an hour.
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
