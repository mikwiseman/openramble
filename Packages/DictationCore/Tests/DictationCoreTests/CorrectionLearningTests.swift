import XCTest
@testable import DictationCore

/// Правила обучения словаря по правке последней диктовки.
///
/// Человек правит текст в нашем окне — diff предлагает замены. Правила
/// консервативны намеренно: научиться мусору хуже, чем не научиться ничему,
/// потому что плохая замена ломает будущие диктовки молча.
final class CorrectionLearningTests: XCTestCase {
    func testСменаПисьменностиДаётЗамену() {
        // Главный сценарий: модель услышала термин кириллицей, человек
        // поправил на латиницу. Ровно это и должно попадать в словарь.
        let proposals = CorrectionLearning.propose(
            original: "Открой поуст герз и проверь индексы.",
            edited: "Открой Postgres и проверь индексы."
        )

        XCTAssertEqual(proposals.map(\.spoken), ["поуст герз"])
        XCTAssertEqual(proposals.map(\.written), ["Postgres"])
    }

    func testГрамматическаяПравкаНеУчится() {
        // «Быстро» → «быстрее» — это правка речи, а не термин. Учить такое
        // значит подменять слова человека в следующих диктовках.
        let proposals = CorrectionLearning.propose(
            original: "Сделай это быстро и аккуратно.",
            edited: "Сделай это быстрее и аккуратно."
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testЛатинскаяПравкаРегистраУчится() {
        // «github» → «GitHub» — написание бренда. Это словарная правка.
        let proposals = CorrectionLearning.propose(
            original: "Загрузи в github ветку.",
            edited: "Загрузи в GitHub ветку."
        )

        XCTAssertEqual(proposals.map(\.spoken), ["github"])
        XCTAssertEqual(proposals.map(\.written), ["GitHub"])
    }

    func testУжеИзвестнаяЗаменаНеПредлагаетсяСнова() {
        let existing = [DictionaryReplacement(spoken: "поуст герз", written: "Postgres")]

        let proposals = CorrectionLearning.propose(
            original: "Открой поуст герз сейчас.",
            edited: "Открой Postgres сейчас.",
            existing: existing
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testНесколькоПравокДаютНесколькоЗамен() {
        let proposals = CorrectionLearning.propose(
            original: "Скинь пул реквест в гит хаб.",
            edited: "Скинь pull request в GitHub."
        )

        XCTAssertEqual(proposals.count, 2)
        XCTAssertEqual(proposals[0].spoken, "пул реквест")
        XCTAssertEqual(proposals[0].written, "pull request")
        XCTAssertEqual(proposals[1].spoken, "гит хаб")
        XCTAssertEqual(proposals[1].written, "GitHub")
    }

    func testУдалениеСловНеДаётЗамен() {
        let proposals = CorrectionLearning.propose(
            original: "Ну вот сделай это сейчас.",
            edited: "Сделай это сейчас."
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testПустыеИОдинаковыеТекстыБезПредложений() {
        XCTAssertTrue(CorrectionLearning.propose(original: "", edited: "").isEmpty)
        XCTAssertTrue(
            CorrectionLearning.propose(
                original: "Один и тот же текст.",
                edited: "Один и тот же текст."
            ).isEmpty
        )
    }

    func testКириллическаяПравкаТерминаНаКириллицуНеУчится() {
        // «сентри» → «центре»-подобные пары без латиницы не проходят фильтр:
        // без сигнала «это термин» слишком велик шанс выучить обычную правку.
        let proposals = CorrectionLearning.propose(
            original: "Мы посмотрели в сентри вчера.",
            edited: "Мы посмотрели в центре вчера."
        )

        XCTAssertTrue(proposals.isEmpty)
    }
}
