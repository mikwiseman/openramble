import LocalASR
import DictationCore
import XCTest

/// Значок в строке меню — единственное постоянное присутствие приложения.
///
/// Картинка без описания для незрячего человека не существует вовсе: VoiceOver
/// прочитает имя системного символа или промолчит.
final class MenuBarStatusTests: XCTestCase {
    func testЗначокРазличаетЗаписьРаботуИПокой() {
        XCTAssertEqual(MenuBarStatus.iconName(state: .listening, isDictationReady: true), "mic.fill")
        XCTAssertEqual(MenuBarStatus.iconName(state: .transcribing, isDictationReady: true), "waveform")
        XCTAssertEqual(MenuBarStatus.iconName(state: .inserting, isDictationReady: true), "waveform")
        XCTAssertEqual(MenuBarStatus.iconName(state: .idle, isDictationReady: true), "mic")
    }

    /// Ненастроенное приложение обязано отличаться значком.
    ///
    /// Иначе человек будет держать клавишу и не понимать, почему ничего не
    /// происходит.
    func testБезНастройкиЗначокПеречёркнут() {
        XCTAssertEqual(MenuBarStatus.iconName(state: .idle, isDictationReady: false), "mic.slash")
    }

    func testУЗначкаЕстьОписаниеВЛюбомСостоянии() {
        let states: [DictationState] = [.idle, .preparing, .listening, .transcribing, .inserting]

        for state in states {
            for ready in [true, false] {
                let label = MenuBarStatus.accessibilityLabel(state: state, isDictationReady: ready)
                XCTAssertFalse(label.isEmpty)
                // В строке меню значков много: «идёт запись» без хозяина
                // ничего не говорит.
                XCTAssertTrue(label.hasPrefix("Wai Dictation"), "«\(label)» не называет приложение")
            }
        }
    }

    func testОписаниеЗначкаНазываетТоЧтоПроисходит() {
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(state: .listening, isDictationReady: true),
            "Wai Dictation: идёт запись"
        )
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(state: .idle, isDictationReady: false),
            "Wai Dictation: нужна настройка"
        )
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(state: .idle, isDictationReady: true),
            "Wai Dictation: готово к диктовке"
        )
    }

    func testПерваяСтрокаМенюГоворитЧтоДелать() {
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .idle, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Правый Command"),
            "Удерживайте Правый Command и говорите"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .idle, isDictationReady: false, isHandsFreeActive: false, hotkeyTitle: "Правый Command"),
            "Нужна настройка"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .listening, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Fn (🌐)"),
            "Слушаю"
        )
    }
}

/// Меню в строке меню: что оно предлагает про модель.
///
/// Раньше меню знало про модель один булев и предлагало «Скачать» даже посреди
/// загрузки: нажатие уходило в никуда, а строка состояния говорила «Нужна
/// настройка», ни словом не упоминая идущую загрузку. Теперь меню берёт те же
/// шесть состояний, что и оба экрана.
@MainActor
final class MenuModelOfferTests: XCTestCase {
    private func status(for state: ModelState) -> ModelStatus {
        ModelStatus.make(state: state, isPreparingEngine: false, place: .settings)
    }

    func testПосредиЗагрузкиНеПредлагаетСкачать() {
        let model = status(for: .downloading(receivedBytes: 200_000_000, totalBytes: 483_105_645))

        XCTAssertFalse(
            model.actions.contains(.install),
            "Пока идёт загрузка, предлагать начать её заново нечестно: нажатие ничего не сделает"
        )
        XCTAssertNotNil(model.progressLabel, "Человек должен видеть, что загрузка идёт")
    }

    func testПосредиПроверкиТожеНеПредлагает() {
        let model = status(for: .verifying(checked: 8, total: 21))

        XCTAssertFalse(model.actions.contains(.install))
        XCTAssertNotNil(model.progressLabel)
    }

    func testПослеОшибкиПредлагаетПовторить() {
        let model = status(for: .failed(.download("сеть недоступна")))

        XCTAssertTrue(model.actions.contains(.retry), "Из ошибки должен быть выход")
    }

    func testКогдаМоделиНетПредлагаетСкачать() {
        let model = status(for: .notInstalled)

        XCTAssertTrue(model.actions.contains(.install))
    }
}

/// Режим без удержания в строке меню.
@MainActor
final class MenuHandsFreeLineTests: XCTestCase {
    func testВРежимеБезУдержанияСказаноКакЗакончить() {
        let line = MenuBarStatus.statusLine(
            state: .listening,
            isDictationReady: true,
            isHandsFreeActive: true,
            hotkeyTitle: "Правый Command"
        )

        XCTAssertTrue(
            line.contains("Правый Command"),
            "Клавишу отпустили, а запись идёт — человек обязан узнать, чем её закончить: \(line)"
        )
    }

    func testВОбычномРежимеЛишнегоНеГоворит() {
        let line = MenuBarStatus.statusLine(
            state: .listening,
            isDictationReady: true,
            isHandsFreeActive: false,
            hotkeyTitle: "Правый Command"
        )

        XCTAssertEqual(line, "Слушаю", "Клавиша зажата — объяснять нечего")
    }
}
