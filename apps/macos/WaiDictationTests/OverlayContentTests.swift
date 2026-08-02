import DictationCore
import XCTest

/// Панель диктовки — единственный канал обратной связи во время диктовки.
///
/// У приложения нет своего окна: если панель промолчала, человек не узнал
/// ничего. Проверяется то, что на ней написано, и то, что о ней говорят вслух.
final class OverlayContentTests: XCTestCase {
    private func content(
        _ state: DictationState,
        notice: DictationNotice? = nil,
        elapsed: TimeInterval = 0
    ) -> OverlayContent {
        OverlayContent.make(state: state, notice: notice, elapsed: elapsed)
    }

    // MARK: - Состояния

    func testКаждоеСостояниеПодписаноПоСвоему() {
        XCTAssertEqual(content(.idle).title, "Готово")
        XCTAssertEqual(content(.preparing).title, "Включаю микрофон…")
        XCTAssertEqual(content(.listening).title, "Слушаю")
        XCTAssertEqual(content(.transcribing).title, "Распознаю…")
        XCTAssertEqual(content(.inserting).title, "Вставляю")
    }

    func testЗаписьОтличаетсяЦветомОтОстального() {
        XCTAssertEqual(content(.listening).tone, .recording)
        XCTAssertEqual(content(.preparing).tone, .working)
        XCTAssertEqual(content(.transcribing).tone, .working)
        XCTAssertEqual(content(.inserting).tone, .working)
        XCTAssertEqual(content(.idle).tone, .idle)
    }

    // MARK: - Счётчик секунд

    /// Секунды — единственный признак, что запись правда идёт.
    func testСчётчикПоказываетсяТолькоТамГдеОнЗначит() {
        XCTAssertEqual(content(.listening, elapsed: 7).subtitle, "7 с")
        XCTAssertEqual(content(.transcribing, elapsed: 12.4).subtitle, "12 с")
        XCTAssertNil(content(.preparing, elapsed: 3).subtitle)
        XCTAssertNil(content(.inserting, elapsed: 3).subtitle)
        XCTAssertNil(content(.idle, elapsed: 3).subtitle)
    }

    func testСчётчикНеУходитВМинус() {
        XCTAssertEqual(content(.listening, elapsed: -2).subtitle, "0 с")
    }

    /// «5 с» VoiceOver читает как «5 эс».
    func testСекундыЧитаютсяСловамиИСклоняются() {
        XCTAssertEqual(OverlayContent.spokenSeconds(1), "1 секунда")
        XCTAssertEqual(OverlayContent.spokenSeconds(2), "2 секунды")
        XCTAssertEqual(OverlayContent.spokenSeconds(4), "4 секунды")
        XCTAssertEqual(OverlayContent.spokenSeconds(5), "5 секунд")
        XCTAssertEqual(OverlayContent.spokenSeconds(11), "11 секунд")
        XCTAssertEqual(OverlayContent.spokenSeconds(12), "12 секунд")
        XCTAssertEqual(OverlayContent.spokenSeconds(21), "21 секунда")
        XCTAssertEqual(OverlayContent.spokenSeconds(22), "22 секунды")
        XCTAssertEqual(OverlayContent.spokenSeconds(25), "25 секунд")
        XCTAssertEqual(OverlayContent.spokenSeconds(111), "111 секунд")
        XCTAssertEqual(OverlayContent.spokenSeconds(0), "0 секунд")
    }

    func testЯрлыкЗаписиНазываетСекундыСловами() {
        XCTAssertEqual(content(.listening, elapsed: 3).accessibilityLabel, "Идёт запись, 3 секунды")
        XCTAssertEqual(content(.listening, elapsed: 1).accessibilityLabel, "Идёт запись, 1 секунда")
    }

    // MARK: - Объявления

    /// Главное объявление во всём приложении.
    ///
    /// Панель нарочно не забирает фокус, значка в доке нет, окна нет: без этой
    /// фразы незрячий человек не знает, что микрофон включён.
    func testНачалоЗаписиОбъявляетсяСрочно() {
        let content = content(.listening)

        XCTAssertEqual(content.announcement, "Идёт запись")
        XCTAssertTrue(content.isAnnouncementUrgent)
    }

    func testРаботаПослеЗаписиТожеОбъявляется() {
        XCTAssertEqual(content(.transcribing).announcement, "Запись остановлена, распознаю речь")
        XCTAssertEqual(content(.inserting).announcement, "Вставляю текст")
        XCTAssertEqual(content(.preparing).announcement, "Включаю микрофон")
    }

    /// Панель в покое убирается с экрана — объявлять там нечего.
    func testПокойНичегоНеОбъявляет() {
        XCTAssertNil(content(.idle).announcement)
    }

    // MARK: - Сообщения

    func testСообщениеЗаменяетСобойСостояние() {
        let notice = DictationNotice(kind: .warning, message: "Текст не вставлен: активен защищённый ввод.")
        let content = content(.listening, notice: notice, elapsed: 9)

        XCTAssertEqual(content.title, notice.message)
        // Счётчик рядом с сообщением сбивает: запись уже не идёт.
        XCTAssertNil(content.subtitle)
        XCTAssertEqual(content.tone, .warning)
        XCTAssertEqual(content.announcement, notice.message)
    }

    func testВидСообщенияВиденИСлышен() {
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .info, message: "и")).tone, .info)
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .warning, message: "п")).tone, .warning)
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .failure, message: "о")).tone, .failure)
    }

    /// Сбой перебивает то, что VoiceOver читает сейчас, а простое уведомление — нет.
    func testСрочностьЗависитОтВидаСообщения() {
        XCTAssertFalse(content(.idle, notice: DictationNotice(kind: .info, message: "и")).isAnnouncementUrgent)
        XCTAssertTrue(content(.idle, notice: DictationNotice(kind: .warning, message: "п")).isAnnouncementUrgent)
        XCTAssertTrue(content(.idle, notice: DictationNotice(kind: .failure, message: "о")).isAnnouncementUrgent)
    }

    // MARK: - Ярлыки

    func testУПанелиВсегдаЕстьЯрлык() {
        let states: [DictationState] = [.idle, .preparing, .listening, .transcribing, .inserting]
        for state in states {
            XCTAssertFalse(
                content(state).accessibilityLabel.isEmpty,
                "состояние \(state) не достаётся VoiceOver вовсе"
            )
        }
    }
}
