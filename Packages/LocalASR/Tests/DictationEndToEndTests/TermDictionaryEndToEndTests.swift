import DictationCore
import Foundation
import XCTest

/// Стартовый словарь на настоящем выходе модели.
///
/// Главный сквозной тест показывает, что цепочка работает. Этот показывает, на
/// каком объёме терминов держится само обещание «сказал по-английски — получил
/// латиницей». Проверять это по частям нельзя: словарь собран по выходу модели,
/// и «правильность» замены существует только вместе с ней.
@MainActor
final class TermDictionaryEndToEndTests: EndToEndScenario {
    private struct Probe {
        let phrase: String
        /// Термины, которые доходят до вставки латиницей.
        let converted: [String]
        /// Термины, которых набор не берёт, и то, как их слышит модель.
        let gaps: [(term: String, heard: String)]

        init(_ phrase: String, converted: [String] = [], gaps: [(term: String, heard: String)] = []) {
            self.phrase = phrase
            self.converted = converted
            self.gaps = gaps
        }
    }

    /// Одиннадцать фраз с терминами разработчика — весь путь до вставки.
    ///
    /// Половина терминов доходит, половина нет, и вторая половина отмечена
    /// `XCTExpectFailure`. Это не подгонка ожидания под модель: ожидание здесь
    /// как раз продуктовое («сказал Sentry — получил Sentry»), просто известная
    /// дыра держится красной, не роняя прогон. Починили одну — упадёт ровно её
    /// строка со словами «expected failure not recorded», и набор пора обновить.
    func testStarterDictionaryOnRealModelOutput() async throws {
        let probes = [
            Probe("Собери build и выложи release.", converted: ["build", "release"]),
            Probe(
                "Мы пишем на Swift, а раньше писали на TypeScript.",
                converted: ["Swift", "TypeScript"]
            ),
            Probe("Этот PR я посмотрю после обеда.", converted: ["PR"]),
            Probe(
                "Выкати rollback без downtime.",
                converted: ["downtime"],
                gaps: [("rollback", "роллбык")]
            ),
            Probe(
                "Включи feature flag на staging.",
                converted: ["staging"],
                gaps: [("feature flag", "фичер флэк")]
            ),
            Probe(
                "Я поправил backend на Python, добавил endpoint и написал hotfix.",
                converted: ["hotfix"],
                gaps: [
                    ("backend", "бэкэнд"),
                    // Не дыра словаря, а потеря слова: вместо термина модель
                    // услышала другое русское слово. Заменой это не чинится.
                    ("Python", "написан"),
                    ("endpoint", "энд поинт"),
                ]
            ),
            Probe(
                "Ошибка прилетела в Sentry, посмотри логи в Docker и в Kubernetes.",
                gaps: [
                    // Осознанный отказ, записанный в docs/benchmarks.md: «центр» —
                    // обычное русское слово, и замена ломала бы «в центре города».
                    ("Sentry", "центре"),
                    ("Docker", "Дакары"),
                    ("Kubernetes", "Кьюберниц"),
                ]
            ),
            Probe(
                "Сделай commit в branch, потом rebase и merge.",
                gaps: [
                    ("commit", "комит"),
                    ("branch", "брандж"),
                    ("rebase", "ребейс"),
                    ("merge", "мордж"),
                ]
            ),
            Probe(
                "Данные в Postgres, кэш в Redis.",
                gaps: [("Postgres", "поезд Герз"), ("Redis", "кэшвербис")]
            ),
            Probe("Открой Xcode и собери проект.", gaps: [("Xcode", "экскоут")]),
            Probe("Сделай code review до обеда.", gaps: [("code review", "коутривью")]),
        ]

        var report: [String] = []

        for probe in probes {
            let text = try await dictated(probe.phrase)
            report.append("  сказано:  \(probe.phrase)")
            report.append("  вставлено: \(text)")

            for term in probe.converted {
                XCTAssertTrue(
                    text.contains(term),
                    "Термин «\(term)» не дошёл латиницей. Пришло: \(text)"
                )
            }

            for gap in probe.gaps {
                XCTExpectFailure(
                    "«\(gap.term)» модель пишет как «\(gap.heard)» — такого написания в наборе нет"
                ) {
                    XCTAssertTrue(
                        text.contains(gap.term),
                        "«\(gap.term)» не дошёл латиницей. Пришло: \(text)"
                    )
                }
            }
        }

        let hits = probes.reduce(0) { $0 + $1.converted.count }
        let misses = probes.reduce(0) { $0 + $1.gaps.count }
        print("\nСтартовый словарь на выходе модели: \(hits) из \(hits + misses) терминов латиницей\n")
        print(report.joined(separator: "\n"))
        print("")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - Один прогон фразы

    private func dictated(
        _ phrase: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> String {
        try await speak(phrase)
        let controller = makeController()
        let before = await inserter.texts.count

        await dictate(with: controller, file: file, line: line)

        let texts = await inserter.texts
        XCTAssertEqual(
            texts.count,
            before + 1,
            "Фраза не дошла до вставки: \(phrase)",
            file: file,
            line: line
        )
        return try XCTUnwrap(texts.last, file: file, line: line)
    }
}
