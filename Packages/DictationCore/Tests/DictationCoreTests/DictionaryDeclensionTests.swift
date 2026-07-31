import XCTest
@testable import DictationCore

/// Замена термина, стоящего в падеже.
///
/// Русское слово склоняется, а латинский термин — нет. Человек говорит «перед
/// релизом» и ждёт «перед release». Точное совпадение здесь не срабатывало
/// никогда, и словарь молчал ровно там, где он и нужен.
final class DictionaryDeclensionTests: XCTestCase {
    private func apply(_ pairs: [(String, String)], to text: String) -> String {
        DictionaryReplacements.apply(
            pairs.map { DictionaryReplacement(spoken: $0.0, written: $0.1) },
            to: text
        )
    }

    func testCasesOfASingleWordTerm() {
        let pairs = [("релиз", "release")]
        XCTAssertEqual(apply(pairs, to: "проверь релиз"), "проверь release")
        XCTAssertEqual(apply(pairs, to: "перед релизом"), "перед release")
        XCTAssertEqual(apply(pairs, to: "после релиза"), "после release")
        XCTAssertEqual(apply(pairs, to: "в релизе"), "в release")
        XCTAssertEqual(apply(pairs, to: "к релизу"), "к release")
    }

    func testTermsEndingInShortI() {
        // «Деплой» склоняется, съедая «й»: деплоя, деплою, деплоем.
        let pairs = [("деплой", "deploy")]
        XCTAssertEqual(apply(pairs, to: "запусти деплой"), "запусти deploy")
        XCTAssertEqual(apply(pairs, to: "после деплоя"), "после deploy")
        XCTAssertEqual(apply(pairs, to: "готовимся к деплою"), "готовимся к deploy")
        XCTAssertEqual(apply(pairs, to: "перед деплоем"), "перед deploy")
    }

    func testPluralsAndCasesTogether() {
        XCTAssertEqual(apply([("докер", "Docker")], to: "подними докеры"), "подними Docker")
        XCTAssertEqual(apply([("коммит", "commit")], to: "три коммита назад"), "три commit назад")
        XCTAssertEqual(apply([("питон", "Python")], to: "бэкенд на питоне"), "бэкенд на Python")
        XCTAssertEqual(apply([("даунтайм", "downtime")], to: "без даунтайма"), "без downtime")
    }

    func testLastWordOfAPhraseAlsoInflects() {
        let pairs = [("пул реквест", "pull request")]
        XCTAssertEqual(apply(pairs, to: "отправь пул реквест"), "отправь pull request")
        XCTAssertEqual(apply(pairs, to: "жду пул реквеста"), "жду pull request")
        XCTAssertEqual(apply(pairs, to: "в пул реквесте"), "в pull request")
    }

    func testExtraSpacesInsideAPhraseDoNotBreakIt() {
        // Распознавание не обещает ровно один пробел.
        XCTAssertEqual(
            apply([("код ревью", "code review")], to: "сделай код  ревью"),
            "сделай code review"
        )
    }

    func testUnrelatedWordsWithTheSameBeginningAreLeftAlone() {
        // Главный риск такой замены — съесть чужое слово.
        XCTAssertEqual(apply([("релиз", "release")], to: "религия"), "религия")
        XCTAssertEqual(apply([("билд", "build")], to: "билдинг"), "билдинг")
        XCTAssertEqual(apply([("коммит", "commit")], to: "коммитить"), "коммитить")
        XCTAssertEqual(apply([("докер", "Docker")], to: "докерфайл"), "докерфайл")
    }

    func testShortTermsStayExact() {
        // У коротких слов хвост слишком часто оказывается началом другого.
        XCTAssertEqual(apply([("апи", "API")], to: "апи отдаёт ответ"), "API отдаёт ответ")
        XCTAssertEqual(apply([("апи", "API")], to: "апиной"), "апиной")
    }

    func testLatinTermsAreNotGivenRussianEndings() {
        // Английские слова в русской речи не склоняются, и лишний хвост там
        // означал бы совсем другое слово.
        XCTAssertEqual(apply([("swift", "Swift")], to: "swifty"), "swifty")
        XCTAssertEqual(apply([("swift", "Swift")], to: "пишем на swift"), "пишем на Swift")
    }

    func testStarterDictionaryCoversWhatTheModelActuallyProduces() {
        // Строки взяты из настоящего прогона модели, а не придуманы.
        let measured = [
            ("Отправь пул реквист на ревью", "pull request"),
            ("Сделай кот ревью", "code review"),
            ("задача в гитхеб", "GitHub"),
            ("базы данных постгриз", "Postgres"),
            ("выкати ход фикс", "hotfix"),
            ("фронтинг на тайп-скрипте", "TypeScript"),
            ("написано на свифте", "Swift"),
        ]

        for (heard, expected) in measured {
            let result = DictionaryReplacements.apply(StarterDictionary.developer, to: heard)
            XCTAssertTrue(
                result.contains(expected),
                "«\(heard)» обязано дать «\(expected)», получилось «\(result)»"
            )
        }
    }
}

/// Чего словарь сделать не может — и не должен пытаться.
final class DictionaryAmbiguityTests: XCTestCase {
    func testOrdinaryRussianWordsAreNotSacrificedForTerms() {
        // Модель пишет «Сентри» как «центре», но «центр» — обычное русское
        // слово. Заменять его на Sentry значит ломать нормальную речь ради
        // одного термина; в замере это единственный случай, который словарь
        // честно не берёт.
        let result = DictionaryReplacements.apply(
            StarterDictionary.developer,
            to: "встретимся в центре города"
        )

        XCTAssertEqual(result, "встретимся в центре города")
    }
}
