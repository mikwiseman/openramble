import DictationCore
import Foundation
import XCTest

/// Замер обещания «текст появляется меньше чем через секунду».
///
/// Мерится весь путь, а не одно распознавание: от момента, когда файл записи
/// готов, до момента, когда текст дошёл до вставки. В этот отрезок входят
/// чтение файла с диска, приведение формата, сама модель, словарь замен и
/// доводка текста — то есть ровно то, что человек ждёт с отпущенной клавишей.
@MainActor
final class DictationLatencyTests: EndToEndScenario {
    private struct Sample {
        let label: String
        /// Длительность записи по данным движка.
        let audio: TimeInterval
        /// Сколько заняла сама модель.
        let inference: TimeInterval
        /// Весь путь «файл готов → текст у вставки».
        let path: TimeInterval

        /// Во сколько раз путь короче самой записи.
        var speedup: Double { path > 0 ? audio / path : 0 }

        var line: String {
            let name = label.padding(toLength: 10, withPad: " ", startingAt: 0)
            let numbers = String(
                format: "%8.2f с | %9.3f с | %9.3f с | %6.0f×",
                audio,
                inference,
                path,
                speedup
            )
            return "| \(name) | \(numbers) |"
        }
    }

    /// Путь от готового файла до текста укладывается в секунду.
    ///
    /// Пороги разные не из-за железа, а из-за смысла: диктовка на пять и на
    /// тридцать секунд — обычный рабочий случай, и там секунда это обещание
    /// продукта. Три минуты — редкий случай, и запас там взят вдвое больший,
    /// чтобы тест не мигал на машине слабее той, где он написан.
    func testPathFromReadyFileToInsertedTextStaysUnderASecond() async throws {
        // Прогрев: первая работа с моделью в процессе всегда дороже остальных,
        // и мерить её значило бы мерить не то.
        _ = try await measure("прогрев", text: Phrase.short)

        // Подписи короткие, а точная длительность записи стоит в таблице рядом:
        // синтез не даёт ровно пять секунд и ровно полминуты.
        let samples = [
            try await measure("фраза", text: Phrase.short),
            try await measure("полминуты", text: Phrase.long),
            try await measure("три минуты", text: Phrase.veryLong),
        ]

        print("\n| запись     |    аудио | распознав. |     весь путь | быстрее РВ |")
        print("|------------|----------|------------|---------------|------------|")
        for sample in samples { print(sample.line) }
        print("")

        for sample in samples where sample.audio < 60 {
            XCTAssertLessThan(
                sample.path,
                1.0,
                "«\(sample.label)»: путь до вставки занял \(sample.path) с — обещали меньше секунды"
            )
        }
        for sample in samples where sample.audio >= 60 {
            XCTAssertLessThan(
                sample.path,
                2.0,
                "«\(sample.label)»: путь до вставки занял \(sample.path) с"
            )
        }

        // Длинная запись обязана разбираться быстрее реального времени с большим
        // запасом: если это перестанет быть так, диктовка на три минуты станет
        // ожиданием, а не диктовкой.
        let longest = try XCTUnwrap(samples.last)
        XCTAssertGreaterThan(
            longest.speedup,
            50,
            "Трёхминутная запись разбирается всего в \(longest.speedup) раз быстрее реального времени"
        )

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - Один замер

    private func measure(_ label: String, text: String) async throws -> Sample {
        try await speak(text)
        let controller = makeController()
        await dictate(with: controller)

        let readyAt = await capture.fileReadyAt
        let insertions = await inserter.insertions
        let results = await probe.results

        let ready = try XCTUnwrap(readyAt, "Запись так и не была закрыта")
        let insertion = try XCTUnwrap(insertions.last, "Текст не дошёл до вставки")
        let result = try XCTUnwrap(results.last, "Модель не ответила")

        return Sample(
            label: label,
            audio: result.audioDuration,
            inference: result.processingDuration,
            path: Self.seconds(ready.duration(to: insertion.at))
        )
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
    }
}
