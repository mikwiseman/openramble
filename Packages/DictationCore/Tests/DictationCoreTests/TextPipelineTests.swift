import XCTest
@testable import DictationCore

final class TranscriptPolisherTests: XCTestCase {
    func testRemovesSpaceBeforePunctuation() {
        XCTAssertEqual(
            TranscriptPolisher.polish("привет , как дела ?"),
            "Привет, как дела?"
        )
    }

    func testAddsSpaceOnlyBeforeNewSentence() {
        // Заглавная буква после точки означает новое предложение — там пробел
        // действительно нужен.
        XCTAssertEqual(
            TranscriptPolisher.polish("Готово.Пойдём дальше"),
            "Готово. Пойдём дальше"
        )
    }

    func testDoesNotBreakNumbersVersionsDomainsAndAbbreviations() {
        // Всё перечисленное реально приходит из модели: она сама превращает
        // «три и четырнадцать сотых» в «3.14». Раньше обработка ставила пробел
        // после любой точки и разваливала числа, версии, домены и сокращения.
        let untouched = [
            "Testing numbers like 3.14 and dates like January 5.",
            "Версия 2.0.1 вышла",
            "Смотри на wai.computer",
            "Это т.д. и т.п.",
            "Цена 1,500 рублей",
        ]

        for input in untouched {
            let output = TranscriptPolisher.polish(input)
            XCTAssertEqual(output, input, "Текст не должен был измениться: \(input)")
        }
    }

    func testCollapsesRepeatedSpaces() {
        XCTAssertEqual(
            TranscriptPolisher.polish("слишком   много    пробелов"),
            "Слишком много пробелов"
        )
    }

    func testKeepsLineBreaks() {
        // Переводы строк осмысленны: пользователь мог продиктовать список.
        XCTAssertEqual(
            TranscriptPolisher.polish("первая строка\nвторая  строка"),
            "Первая строка\nвторая строка"
        )
    }

    func testCapitalizesOnlyTheFirstLetter() {
        XCTAssertEqual(
            TranscriptPolisher.polish("привет мир"),
            "Привет мир"
        )
        // Уже заглавную не трогаем, аббревиатуры не ломаем.
        XCTAssertEqual(TranscriptPolisher.polish("HTTP это протокол"), "HTTP это протокол")
    }

    func testDoesNotTouchNumbersWrittenAsWords() {
        // Разворачивать числительные в цифры не пытаемся: в русском это
        // упирается в падежи и ломает больше, чем чинит.
        XCTAssertEqual(
            TranscriptPolisher.polish("двадцать пять рублей"),
            "Двадцать пять рублей"
        )
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(TranscriptPolisher.polish("   "), "")
    }
}

final class DictionaryReplacementsTests: XCTestCase {
    func testReplacesWholeWordsOnly() {
        let replacements = [DictionaryReplacement(spoken: "код", written: "code")]

        // «кодировка» не должна превратиться в «codeировка».
        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "код и кодировка"),
            "code и кодировка"
        )
    }

    func testIsCaseInsensitiveOnInput() {
        // Распознавание не гарантирует регистр, а результат должен быть стабилен.
        let replacements = [DictionaryReplacement(spoken: "сентри", written: "Sentry")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "Сентри упал"),
            "Sentry упал"
        )
    }

    func testLongerPhrasesWinOverShorterOnes() {
        let replacements = [
            DictionaryReplacement(spoken: "пул", written: "pull"),
            DictionaryReplacement(spoken: "пул реквест", written: "pull request"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "закинул пул реквест"),
            "закинул pull request"
        )
    }

    func testHandlesRussianEnglishMix() {
        // Главный сценарий продукта.
        let replacements = [
            DictionaryReplacement(spoken: "деплой", written: "deploy"),
            DictionaryReplacement(spoken: "ревью", written: "review"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "сделай ревью и деплой"),
            "сделай review и deploy"
        )
    }

    func testEmptyDictionaryLeavesTextIntact() {
        XCTAssertEqual(DictionaryReplacements.apply([], to: "текст"), "текст")
    }
}

final class TrailingCommandParserTests: XCTestCase {
    func testDetectsSendCommandAtTheEnd() {
        let result = TrailingCommandParser.parse("привет как дела отправь")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "привет как дела")
    }

    func testIgnoresCommandWordInTheMiddle() {
        // «отправь» в середине — обычное слово, а не команда.
        let result = TrailingCommandParser.parse("отправь ему письмо завтра")

        XCTAssertNil(result.command)
        XCTAssertEqual(result.text, "отправь ему письмо завтра")
    }

    func testToleratesTrailingPunctuation() {
        let result = TrailingCommandParser.parse("готово, отправь.")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "готово")
    }

    func testTextWithoutCommandStaysWhole() {
        let result = TrailingCommandParser.parse("просто текст")

        XCTAssertNil(result.command)
        XCTAssertEqual(result.text, "просто текст")
    }
}

final class TextPipelineTests: XCTestCase {
    func testFullPathFromRecognizedToInsertable() {
        let pipeline = TextPipeline(replacements: [
            DictionaryReplacement(spoken: "сентри", written: "Sentry"),
        ])

        let output = pipeline.process("сентри снова упал , посмотри отправь")

        XCTAssertEqual(output.text, "Sentry снова упал, посмотри")
        XCTAssertEqual(output.command, .pressReturn)
    }

    func testCommandIsStrippedBeforeDictionaryRuns() {
        // Порядок важен: если сначала применить словарь, он может задеть
        // слово команды и та перестанет распознаваться.
        let pipeline = TextPipeline(replacements: [
            DictionaryReplacement(spoken: "отправь", written: "ОТПРАВЬ"),
        ])

        let output = pipeline.process("готово отправь")

        XCTAssertEqual(output.command, .pressReturn)
        XCTAssertEqual(output.text, "Готово")
    }

    func testEmptyRecognitionProducesEmptyOutput() {
        let output = TextPipeline().process("   ")

        XCTAssertEqual(output.text, "")
        XCTAssertNil(output.command)
    }
}
