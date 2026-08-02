import XCTest
@testable import DictationCore

/// Фонетический ключ: что он считает одним словом, а что разными.
///
/// Тесты написаны от правил русской фонетики, а не от списка удачных случаев:
/// сломается правило — упадёт строка, объясняющая, какое именно.
final class PhoneticKeyTests: XCTestCase {
    private func same(_ left: String, _ right: String, _ why: String) {
        XCTAssertEqual(
            PhoneticKey.of(left), PhoneticKey.of(right),
            "«\(left)» и «\(right)» должны быть одним словом: \(why)"
        )
    }

    private func different(_ left: String, _ right: String, _ why: String) {
        XCTAssertNotEqual(
            PhoneticKey.of(left), PhoneticKey.of(right),
            "«\(left)» и «\(right)» должны остаться разными: \(why)"
        )
    }

    func testUnstressedVowelsCollapse() {
        same("диплой", "деплой", "безударные «и» и «е» звучат одинаково")
        same("бэкэнд", "бэкенд", "«э» и «е» — одна гласная")
        same("камит", "комит", "безударное «о» звучит как «а»")
        same("мордж", "мёрдж", "«ё» — это «о» после мягкого")
    }

    func testDoubledLettersCollapse() {
        same("комит", "коммит", "удвоение на слух не различается")
        same("рилис", "риллис", "то же самое")
    }

    func testVoicingCollapsesOnlyWhereRussianNeutralisesIt() {
        same("ребейс", "ребейз", "в конце слова звонкие оглушаются")
        same("фронтент", "фронтенд", "то же самое")
        same("хотфикс", "ходфикс", "перед глухим «ф» звонкая «д» оглушается")

        // Ради этих трёх строк оглушение и сделано позиционным. Без них набор
        // съедал 161 обычное русское слово вместо 70 — при том же выигрыше.
        different("теплой", "деплой", "в начале слова русский ничего не оглушает")
        different("бетон", "питон", "то же самое")
        different("протёкш", "продакш", "между гласными оглушения нет")
    }

    func testFinalVowelIsNeverFolded() {
        // Главная защита словаря: в последней гласной живёт падежное окончание.
        different("центре", "центри", "иначе «в центре города» станет «в Sentry города»")
        different("комете", "комети", "та же причина")
    }

    func testSoftSignIsPartOfTheWord() {
        different("камедь", "камет", "мягкий знак — не украшение")
        different("ревю", "ревью", "«ревю» — своё слово")
    }
}

/// Второй проход словаря на настоящем выходе модели.
///
/// Все левые части взяты из прогона Parakeet: это то, что модель написала на
/// самом деле, когда голос произносил английский термин внутри русской фразы.
/// Ни одного из этих написаний в словаре нет и быть не может — в другой фразе
/// то же слово выйдет иначе.
final class PhoneticMatchingTests: XCTestCase {
    private func polished(_ text: String) -> String {
        DictionaryReplacements.apply(StarterDictionary.developer, to: text)
    }

    func testSpellingsTheDictionaryNeverSawAreStillRecognised() {
        let measured = [
            ("Запусти диплой в пятницу вечером.", "deploy"),
            ("Я поправил бэкэнд и залил изменения.", "backend"),
            ("Сделай комит в ветку.", "commit"),
            ("Потом ребейс и мордж.", "merge"),
            ("Потом ребейс и мордж.", "rebase"),
            ("Выкати роллбык без простоя.", "rollback"),
            ("Фронтент работает медленно.", "frontend"),
            ("Мы выкатили риллис вчера ночью.", "release"),
        ]

        for (heard, expected) in measured {
            XCTAssertTrue(
                polished(heard).contains(expected),
                "«\(heard)» обязано дать «\(expected)», получилось «\(polished(heard))»"
            )
        }
    }

    func testTermSplitInTwoWordsIsGluedBack() {
        // Модель то склеивает термин, то разрывает — в одной и той же записи.
        XCTAssertEqual(polished("выкатывай без даун тайма"), "выкатывай без downtime")
        XCTAssertEqual(polished("добавил энд поинт"), "добавил endpoint")
        XCTAssertEqual(polished("напиши на джава скрипте"), "напиши на JavaScript")
        XCTAssertEqual(polished("мы пишем на тайп скрипте"), "мы пишем на TypeScript")
    }

    func testUnknownSpellingInAnObliqueCaseIsRecognised() {
        // Русский склоняет термин, а модель пишет его как слышит. Встречаются
        // обе беды сразу, и чаще всего именно так.
        XCTAssertEqual(polished("сразу после диплоя"), "сразу после deploy")
        XCTAssertEqual(polished("перед диплоем"), "перед deploy")
        XCTAssertEqual(polished("работа над бэкэндом"), "работа над backend")
    }

    func testWordsBrokenByPunctuationAreNotGluedTogether() {
        // «Энд, поинт» — два разных места фразы, а не разорванный термин.
        XCTAssertEqual(polished("сказал энд, поинт не трогай"), "сказал энд, поинт не трогай")
    }

    // MARK: - Чего фонетика не делает

    func testShortReplacementsStayExact() {
        // У коротких слов на один ключ приходится слишком много обычной речи.
        let replacements = [DictionaryReplacement(spoken: "апи", written: "API")]
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "эпи и опа"), "эпи и опа")
    }

    func testLatinReplacementsAreNotMatchedPhonetically() {
        // Правила русские: применять их к латинице значит гадать.
        let replacements = [DictionaryReplacement(spoken: "swift", written: "Swift")]
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "sweft"), "sweft")
    }

    func testDeletingReplacementsAreNeverMatchedPhonetically() {
        // Пустая правая часть вычёркивает слово-паразит. Вычеркнуть по догадке
        // нельзя: подменённое слово человек в тексте увидит, а исчезнувшее —
        // нет. Цена честная: «кароче» придётся вычеркнуть отдельной записью.
        let replacements = [DictionaryReplacement(spoken: "короче", written: "")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "кароче я пошёл"),
            "кароче я пошёл"
        )
        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "короче я пошёл"),
            " я пошёл"
        )
    }

    func testOneKeyForTwoTermsIsNotAGuess() {
        // Если две записи звучат одинаково, а пишутся по-разному — выбирать
        // нельзя. Точное совпадение при этом продолжает работать.
        let replacements = [
            DictionaryReplacement(spoken: "рэндом", written: "random"),
            DictionaryReplacement(spoken: "рындам", written: "rundum"),
        ]
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "рындом"), "рындом")
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "рэндом"), "random")
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "рындам"), "rundum")
    }

    func testDigitsNextToLettersMakeADifferentWord() {
        let replacements = [DictionaryReplacement(spoken: "деплой", written: "deploy")]
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "диплой2"), "диплой2")
    }
}

/// Цена сопоставления: обычная русская речь.
///
/// Это главный тест словаря. Продукт, который портит нормальную речь, хуже
/// продукта, который не узнаёт термин: пропущенный термин человек видит и
/// правит, подменённое слово — нет.
///
/// Список слов не выдуман. Он получен перебором: для каждой записи словаря
/// построены все написания с тем же фонетическим ключом, и системный
/// проверяльщик орфографии отобрал из них настоящие русские слова. Здесь —
/// весь улов.
final class DictionaryFalsePositiveTests: XCTestCase {
    private func assertUntouched(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            DictionaryReplacements.apply(StarterDictionary.developer, to: text),
            text,
            file: file,
            line: line
        )
    }

    func testOrdinaryRussianSpeechSurvivesTheStarterDictionary() {
        let speech = [
            // Раньше набор превращал это в «на commit в телескоп».
            "вчера мы смотрели на комету в телескоп",
            "комета Галлея вернётся не скоро",
            "он написал реферат о комете",
            "кометы видно только в ясную ночь",
            // Раньше — «Docker разгружали судно».
            "докеры разгружали судно в порту",
            "докер работал в ночную смену",
            // Раньше — «Python сжал добычу».
            "питон сжал добычу и замер",
            "питоны спят почти всё время",
            // Раньше — «на грядке растут Redis».
            "на грядке растут редис и укроп",
            "мы пошли на бранч в воскресенье",
            // Всегда работало и обязано работать дальше.
            "встретимся в центре города",
            "центральная улица была перекрыта",
            // Появилось бы, сворачивай мы звонкость где попало.
            "в тёплой воде плавали утки",
            "бетон застыл только к утру",
            "бидон с молоком стоял в сенях",
            "мы рылись в старых бумагах весь вечер",
            "протёкшая крыша испортила потолок",
            "камедь на стволе вишни застыла каплями",
            "экзоты в этой оранжерее не приживаются",
            "вечернее ревю мы досмотрели до конца",
            // Просто похожие слова.
            "на льдине сидел морж",
            "комитет собрался в среду",
            "доктор велел больше гулять",
            "линейку я потерял ещё в прошлом году",
            "продавщица посоветовала взять батон посвежее",
        ]

        for phrase in speech {
            assertUntouched(phrase)
        }
    }

    func testConnectedSpeechIsNotTouchedAnywhere() {
        // Связный кусок, а не набор отдельных слов: подмена посреди фразы
        // заметна хуже всего.
        assertUntouched("""
            Сегодня утром я вышел из дома пораньше и успел на первый автобус. \
            В центре города было пусто, только дворники мели тротуары. \
            Доктор советовал больше гулять, и я решил пройтись пешком до парка, \
            где мы договорились встретиться у старой водонапорной башни. \
            Вечером пошёл дождь, и все спрятались под навесом у магазина на углу.
            """)
    }

    func testVoicingIsNotFoldedWhereRussianKeepsIt() {
        // Правило проверяется и на пользовательской записи: набор её больше не
        // содержит, а человек такую заводит.
        let replacements = [DictionaryReplacement(spoken: "питон", written: "Python")]
        for phrase in ["бетон застыл к утру", "бидон с молоком", "бутон раскрылся"] {
            XCTAssertEqual(DictionaryReplacements.apply(replacements, to: phrase), phrase)
        }
        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "скрипты у нас на питоне"),
            "скрипты у нас на Python"
        )
    }
}
