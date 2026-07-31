import XCTest
@testable import DictationCore

/// Словарь пользователь наполняет руками, и туда попадает что угодно:
/// «т.д.», «c++», «:)», пустая правая часть. Внутри замена — регулярное
/// выражение, а значит, любой такой символ может из текста превратиться в
/// инструкцию. Испорченная замена ломает не одно слово, а всю фразу, и
/// человек об этом узнаёт уже после вставки в чужое окно.
final class DictionaryReplacementsEdgeCaseTests: XCTestCase {

    // MARK: - Спецсимволы в том, что слышно

    func testDotsInTheSpokenFormAreTakenLiterally() {
        // Сокращения с точками — обычное дело в словаре. Точка в регулярном
        // выражении означает «любой символ», и без экранирования правило
        // «т.д.» задело бы всё похожее по длине.
        let replacements = [DictionaryReplacement(spoken: "т.д.", written: "так далее")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "молоко, хлеб и т.д. купи"),
            "молоко, хлеб и так далее купи"
        )
        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "тхдх не трогаем"),
            "тхдх не трогаем"
        )
    }

    func testPlusesAndBracketsInTheSpokenFormDoNotBreakTheRule() {
        // «c++» и «:)» — валидные записи словаря и одновременно куски
        // регулярного выражения. Незаэкранированные скобки делают выражение
        // недопустимым, и правило молча перестаёт работать целиком.
        let replacements = [
            DictionaryReplacement(spoken: "c++", written: "C++"),
            DictionaryReplacement(spoken: ":)", written: "🙂"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "пишу на c++ и рад :)"),
            "пишу на C++ и рад 🙂"
        )
    }

    func testStarInTheSpokenFormMatchesTheStarItself() {
        // Звёздочка в регулярном выражении — повтор предыдущего символа.
        // В словаре это просто символ.
        let replacements = [DictionaryReplacement(spoken: "*", written: "звёздочка")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "поставь * тут"),
            "поставь звёздочка тут"
        )
    }

    // MARK: - Спецсимволы в том, что пишется

    func testDollarInTheWrittenFormIsNotATemplateReference() {
        // В шаблоне замены «$1» означает «первая захваченная группа». Без
        // экранирования цена «$100» превратилась бы в «00»: пользователь
        // получил бы тихо испорченный текст, а не ошибку.
        let replacements = [DictionaryReplacement(spoken: "цена", written: "$100")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "цена вопроса"),
            "$100 вопроса"
        )
    }

    func testBackslashInTheWrittenFormSurvives() {
        let replacements = [DictionaryReplacement(spoken: "перенос", written: #"\n"#)]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "тут перенос строки"),
            #"тут \n строки"#
        )
    }

    // MARK: - Вырожденные записи

    func testEmptyWrittenFormRemovesTheWordWithoutLeavingHoles() {
        // Пустая правая часть — способ убрать слово-паразит. После удаления
        // остаются два пробела подряд, и убрать их обязан конвейер, иначе
        // «чистка» будет заметнее самого паразита.
        let pipeline = TextPipeline(replacements: [
            DictionaryReplacement(spoken: "короче", written: ""),
        ])

        XCTAssertEqual(pipeline.process("короче нужно сделать короче быстро").text, "Нужно сделать быстро")
    }

    func testWhitespaceOnlySpokenFormIsIgnored() {
        // Пустая левая часть — оставленная по невнимательности строка словаря.
        // Правило «заменить пробел» переписало бы весь текст целиком.
        let replacements = [
            DictionaryReplacement(spoken: "   ", written: "ПРОБЕЛ"),
            DictionaryReplacement(spoken: "", written: "ПУСТО"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "обычный текст без сюрпризов"),
            "обычный текст без сюрпризов"
        )
    }

    func testSelfReplacementOnlyNormalizesTheCase() {
        // Слово, заменённое само на себя, встречается, когда человек правит
        // словарь и передумывает. Ничего страшного произойти не должно:
        // ни зацикливания, ни удвоения — только приведение к записанной форме.
        let replacements = [DictionaryReplacement(spoken: "Swift", written: "Swift")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "пишу на swift каждый день"),
            "пишу на Swift каждый день"
        )
    }

    // MARK: - Границы слова

    func testReplacementWorksAtBothEndsOfTheText() {
        let replacements = [DictionaryReplacement(spoken: "деплой", written: "deploy")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "деплой прошёл, повторим деплой"),
            "deploy прошёл, повторим deploy"
        )
    }

    func testDigitsCountAsPartOfAWord() {
        // «апи2» — не «апи»: иначе версия в конце слова потеряла бы смысл.
        let replacements = [DictionaryReplacement(spoken: "апи", written: "API")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "апи2 и апи"),
            "апи2 и API"
        )
    }

    // MARK: - Порядок правил

    func testLaterRuleCanRewriteWhatAnEarlierRuleProduced() {
        // Правила применяются по очереди к уже изменённому тексту, длинные
        // первыми. Значит, короткое правило видит результат длинного — и это
        // ровно то, что происходит, когда человек заводит взаимно
        // пересекающиеся замены. Поведение зафиксировано намеренно: оно должно
        // быть предсказуемым, а не зависеть от порядка строк в списке.
        let replacements = [
            DictionaryReplacement(spoken: "пул реквест", written: "PR"),
            DictionaryReplacement(spoken: "PR", written: "пиар"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "открой пул реквест"),
            "открой пиар"
        )
    }

    // MARK: - Большой словарь

    func testLargeDictionaryStaysCorrectAndFast() {
        // Словарь растёт годами: пятьсот терминов — это правдоподобный размер
        // для человека, который диктует каждый день. Замена идёт в момент,
        // когда пользователь уже ждёт текст, поэтому важны обе стороны:
        // и что нужное правило сработало, и что это не заняло секунды.
        var replacements = (0..<500).map {
            DictionaryReplacement(spoken: "термин\($0)", written: "term\($0)")
        }
        replacements.append(DictionaryReplacement(spoken: "сентри", written: "Sentry"))

        let text = "Сегодня упал сентри, посмотри логи и напиши в чат, что всё под контролем"

        let started = Date()
        let result = DictionaryReplacements.apply(replacements, to: text)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.contains("Sentry"))
        XCTAssertFalse(result.contains("сентри"))
        // Порог грубый: он ловит не медленную машину, а случайно занесённую
        // квадратичную обработку.
        XCTAssertLessThan(elapsed, 3, "Замена по большому словарю заняла \(elapsed) с")
    }
}
