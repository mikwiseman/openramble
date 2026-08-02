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
            MenuBarStatus.statusLine(state: .idle, isDictationReady: true, hotkeyTitle: "Правый Command"),
            "Удерживайте Правый Command и говорите"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .idle, isDictationReady: false, hotkeyTitle: "Правый Command"),
            "Нужна настройка"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .listening, isDictationReady: true, hotkeyTitle: "Fn (🌐)"),
            "Слушаю"
        )
    }
}
