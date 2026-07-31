import XCTest
@testable import DictationCore

/// Разбор завершающей команды — самое опасное место конвейера.
///
/// Ошибка в одну сторону съедает слово из текста, в другую — нажимает Return
/// в чужом окне. Нажатие уже не отозвать: сообщение уйдёт, форма отправится.
/// Поэтому команда должна опознаваться только там, где человек её задумал.
final class TrailingCommandEdgeCaseTests: XCTestCase {

    // MARK: - Команда внутри слова

    func testWordThatMerelyEndsLikeACommandIsNotACommand() {
        // «Переотправь» и «отправьте» — обычные слова. Если счесть их командой,
        // из текста пропадёт слово, а в приложение уйдёт нажатие Return.
        for text in ["письмо переотправь", "сделай отправьте", "надо переотправить"] {
            let result = TrailingCommandParser.parse(text)

            XCTAssertNil(result.command, "Текст: \(text)")
            XCTAssertEqual(result.text, text)
        }
    }

    func testCommandGluedToPreviousWordIsNotACommand() {
        // Без пробела перед командой это часть слова, а не отдельное слово.
        let result = TrailingCommandParser.parse("готовоотправь")

        XCTAssertNil(result.command)
        XCTAssertEqual(result.text, "готовоотправь")
    }

    // MARK: - Регистр

    func testCommandIsRecognizedRegardlessOfCase() {
        // Модель ставит заглавную в начале фразы и после точки, а команда могла
        // оказаться именно там. От регистра распознавание команды зависеть
        // не должно, а вот текст перед ней обязан сохранить свой.
        let result = TrailingCommandParser.parse("Готово, ОТПРАВЬ")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "Готово")
    }

    func testTextKeepsItsOwnCaseAfterCommandIsCutOff() {
        let result = TrailingCommandParser.parse("Пиши Диме в Telegram Отправь")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "Пиши Диме в Telegram")
    }

    // MARK: - Юникод

    func testTextWithUnusualLettersIsCutCorrectly() {
        // «İ» при переводе в нижний регистр становится двумя символами, и
        // длина строки меняется. Если резать текст по позициям, найденным в
        // приведённой копии, обрежется не там: пользователь получит покалеченное
        // слово вместо своего текста.
        let result = TrailingCommandParser.parse("Летим в İstanbul отправь")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "Летим в İstanbul")
    }

    func testEmojiBeforeCommandSurvives() {
        let result = TrailingCommandParser.parse("готово 🎉 отправь")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "готово 🎉")
    }

    // MARK: - Несколько команд подряд

    func testOnlyTheLastCommandIsTakenOff() {
        // Человек повторил команду или модель услышала её дважды. Снимаем ровно
        // одну: остальное — текст, и решать за пользователя, что он имел в виду,
        // мы не станем.
        let result = TrailingCommandParser.parse("готово отправь отправь")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "готово отправь")
    }

    func testDifferentCommandsInARowLeaveOnlyTheLastOne() {
        let result = TrailingCommandParser.parse("текст новая строка отправь")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "текст новая строка")
    }

    // MARK: - Пусто после команды

    func testDictationConsistingOnlyOfTheCommandStaysText() {
        // Раньше такая диктовка проваливалась в никуда: текста не оставалось,
        // а вставка пустой строки вместе с ней отменяла и нажатие Return —
        // человек нажимал клавишу, говорил слово и не получал ничего.
        //
        // Одно слово — это слово. Нажать Return в чужом окне по такой догадке
        // нельзя: отправленное сообщение не отзывается.
        for text in ["отправь", "Отправь.", "новая строка"] {
            let result = TrailingCommandParser.parse(text)

            XCTAssertNil(result.command, "Текст: \(text)")
            XCTAssertFalse(result.text.isEmpty, "Текст: \(text)")
        }
    }

    func testCommandAfterPunctuationOnlyTextStaysText() {
        // После снятия команды остаются одни знаки препинания — значащего
        // текста нет, и это тот же случай, что и команда в одиночку.
        let result = TrailingCommandParser.parse(", отправь")

        XCTAssertNil(result.command)
    }

    // MARK: - Хвост фразы

    func testTrailingPunctuationAndSpacesDoNotHideTheCommand() {
        for text in ["всё готово, отправь.", "всё готово отправь!  ", "всё готово: отправь..."] {
            let result = TrailingCommandParser.parse(text)

            XCTAssertEqual(result.command, .pressReturn, "Текст: \(text)")
            XCTAssertEqual(result.text, "всё готово", "Текст: \(text)")
        }
    }

    func testEnglishMultiWordCommandWorks() {
        let result = TrailingCommandParser.parse("looks good send it")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "looks good")
    }

    func testNewLineCommandIsRecognizedSeparately() {
        let result = TrailingCommandParser.parse("первый пункт новая строка")

        XCTAssertEqual(result.command, .newLine)
        XCTAssertEqual(result.text, "первый пункт")
    }

    // MARK: - Пустой вход

    func testEmptyInputHasNeitherTextNorCommand() {
        let result = TrailingCommandParser.parse("   \n  ")

        XCTAssertNil(result.command)
        XCTAssertTrue(result.text.isEmpty)
    }
}
