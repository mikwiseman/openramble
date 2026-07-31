import XCTest
@testable import asr_bench

/// Скорер — единственное, на чём держатся все цифры качества. Если он врёт,
/// врут и выводы, причём незаметно: неправильная нормализация превращает верное
/// распознавание в ошибку и наоборот.
final class TranscriptScorerTests: XCTestCase {
    private func words(_ text: String) -> [String] {
        TextNormalizer.normalize(text).words
    }

    // MARK: - Числительные

    func testFoldsRussianCardinalToDigits() {
        XCTAssertEqual(words("сто двадцать восемь мегабайт"), ["128", "мегабайт"])
        XCTAssertEqual(words("двести пятьдесят"), ["250"])
        XCTAssertEqual(words("две тысячи четыреста строк"), ["2400", "строк"])
        XCTAssertEqual(words("девятьсот девяносто девять рублей"), ["999", "рублей"])
    }

    func testFoldsOrdinalAndCaseFormsToTheSameNumber() {
        // Ради этого свёртка идёт в цифры, а не в слова: русский меняет
        // числительному и род, и падеж, а число остаётся тем же.
        for form in ["двадцать пятое", "двадцать пятого", "двадцать пять", "двадцати пяти"] {
            XCTAssertEqual(words(form), ["25"], "Форма «\(form)» свернулась не в 25")
        }
    }

    func testDigitsAndWordsCompareEqual() {
        let report = TranscriptScorer.score(
            reference: "файл весит сто двадцать восемь мегабайт",
            hypothesis: "Файл весит 128 мегабайт."
        )

        XCTAssertEqual(report.words.errors, 0, "Цифры и слова должны сравниваться как одно и то же")
    }

    func testOrdinalWithHyphenSuffixIsANumber() {
        // Модель пишет «10-я мысль» там, где сказано «десятая мысль».
        XCTAssertEqual(words("10-я мысль"), ["10", "мысль"])
        XCTAssertEqual(words("десятая мысль"), ["10", "мысль"])
    }

    func testTimeIsNotSummedIntoOneNumber() {
        // «четырнадцать тридцать» — это время. Сложение дало бы 44 и спрятало
        // бы любую ошибку в часах или минутах.
        XCTAssertEqual(words("в четырнадцать тридцать"), ["в", "14", "30"])
        XCTAssertEqual(words("at nine forty five"), ["at", "9", "45"])
    }

    func testHalfBecomesFraction() {
        XCTAssertEqual(words("три с половиной часа"), ["3.5", "часа"])
        XCTAssertEqual(words("one and a half hours"), ["1.5", "hours"])
    }

    func testDecimalSeparatorStaysInsideNumber() {
        XCTAssertEqual(words("версия 2.01"), ["версия", "2.01"])
        XCTAssertEqual(words("занял 3,5 часа"), ["занял", "3.5", "часа"])
    }

    func testPrepositionIsNotSwallowedByNumber() {
        // «с» служебно только в «с половиной». В «три с утра» это предлог,
        // и потерять его скорер не имеет права.
        XCTAssertEqual(words("три с утра"), ["3", "с", "утра"])
    }

    func testEnglishHundredMultiplies() {
        XCTAssertEqual(words("three hundred and twenty one files"), ["321", "files"])
        XCTAssertEqual(words("two hundred milliseconds"), ["200", "milliseconds"])
    }

    func testNonNumbersAreLeftAlone() {
        // «сто» и «стол» отличаются одной буквой — угадывание по основе
        // превратило бы мебель в число.
        XCTAssertEqual(words("стол и стойка"), ["стол", "и", "стойка"])
        XCTAssertEqual(words("одиночество"), ["одиночество"])
    }

    // MARK: - Пунктуация

    func testPunctuationIsNotSilentlyDropped() {
        let normalized = TextNormalizer.normalize("Привет, как дела? Всё хорошо!")

        XCTAssertEqual(normalized.marks, [",", "?", "!"], "Знаки обязаны попадать в отдельный поток")
        XCTAssertFalse(normalized.words.contains(where: { $0.contains(",") }))
        XCTAssertTrue(normalized.tokens.contains(","), "Знаки должны быть видны и в общем потоке токенов")
    }

    func testMissingPunctuationCostsNothingInWordsButShowsUpSeparately() {
        let report = TranscriptScorer.score(
            reference: "привет, как дела?",
            hypothesis: "привет как дела"
        )

        XCTAssertEqual(report.words.errors, 0, "Слова распознаны верно")
        XCTAssertEqual(report.punctuation.deletions, 2, "Потерянные знаки обязаны быть посчитаны")
        XCTAssertGreaterThan(
            report.wordsWithPunctuation.rate,
            report.words.rate,
            "Цена пунктуации должна быть видна в отдельной метрике"
        )
    }

    func testInnerHyphenAndApostropheStayInsideWord() {
        XCTAssertEqual(words("тайп-скрипт"), ["тайп-скрипт"])
        XCTAssertEqual(words("don't stop"), ["don't", "stop"])
        XCTAssertEqual(TextNormalizer.normalize("да — нет").marks, ["—"])
    }

    func testPercentSignIsSeparatedButIsNotPunctuation() {
        let normalized = TextNormalizer.normalize("скидка 75%")

        XCTAssertEqual(normalized.words, ["скидка", "75"], "Число не должно слипаться с символом")
        XCTAssertTrue(normalized.marks.isEmpty, "Процент — не знак препинания")
    }

    // MARK: - Подсчёт ошибок

    func testCountsSubstitutionsDeletionsAndInsertions() {
        let report = TranscriptScorer.score(
            reference: "утро день вечер ночь",
            hypothesis: "утро дань вечер ночь снова"
        )

        XCTAssertEqual(report.words.substitutions, 1)
        XCTAssertEqual(report.words.insertions, 1)
        XCTAssertEqual(report.words.deletions, 0)
        XCTAssertEqual(report.words.referenceLength, 4)
        XCTAssertEqual(report.words.rate, 0.5, accuracy: 0.0001)
    }

    func testDeletionIsReportedAsLostWord() {
        let report = TranscriptScorer.score(
            reference: "нужно сохранить последнюю фразу",
            hypothesis: "нужно сохранить фразу"
        )

        XCTAssertEqual(report.words.deletions, 1)
        XCTAssertEqual(
            report.differences.map(\.description),
            ["пропало «последнюю»"],
            "Пропавшее слово обязано быть названо: молчаливая потеря — главный дефект"
        )
    }

    func testEmptyReferenceWithTextIsFullError() {
        // Тишина, из которой родился текст, — это стопроцентная ошибка,
        // а не ноль из-за деления на ноль.
        let report = TranscriptScorer.score(reference: "", hypothesis: "откуда-то взялся текст")

        XCTAssertEqual(report.words.rate, 1)
        XCTAssertEqual(report.characterErrorRate, 1)
    }

    func testSilenceMatchedBySilenceIsNotAnError() {
        let report = TranscriptScorer.score(reference: "", hypothesis: "")

        XCTAssertEqual(report.words.rate, 0)
        XCTAssertEqual(report.characterErrorRate, 0)
    }

    func testCaseAndYoAreNotErrors() {
        let report = TranscriptScorer.score(
            reference: "Всё готово",
            hypothesis: "все ГОТОВО"
        )

        XCTAssertEqual(report.words.errors, 0)
    }

    func testCharacterErrorRateCountsLetters() {
        let report = TranscriptScorer.score(reference: "кот", hypothesis: "код")

        XCTAssertEqual(report.words.rate, 1, "Одно слово из одного — целиком ошибка")
        XCTAssertEqual(report.characterErrorRate, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testAlignmentAgreesWithLevenshteinDistance() {
        // Путь и расстояние считаются разными функциями; если они разойдутся,
        // разойдутся и WER с CER.
        let reference = "один два три четыре пять шесть".split(separator: " ").map(String.init)
        let hypothesis = "один три четыре пять восемь семь".split(separator: " ").map(String.init)

        let (counts, _) = TranscriptScorer.align(reference, hypothesis)
        // Те же последовательности, но по одному символу на слово: расстояние
        // считается другой функцией, и разойтись они не имеют права.
        let distance = TranscriptScorer.distance(
            Array(reference.map { $0.first! }),
            Array(hypothesis.map { $0.first! })
        )

        XCTAssertEqual(counts.errors, distance, "Выравнивание и расстояние обязаны совпадать")
    }
}
