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

    func testОбычнаяПравкаРечиНаЛатиницеНеУчится() {
        // Тот же запрет, что и для «быстро» → «быстрее», но в тексте, где
        // латиница есть с обеих сторон. Раньше признаком термина считалось
        // «справа есть латиница» — в английском тексте он не значил ничего, и
        // сюда проваливалась любая правка слов.
        for (original, edited) in [
            ("please send me the file", "please send me a file"),
            ("the quick brown fox jumps", "the slow brown fox jumps"),
            ("I went to the store today", "I ran to the store today"),
        ] {
            XCTAssertTrue(
                CorrectionLearning.propose(original: original, edited: edited).isEmpty,
                "Правка речи «\(original)» → «\(edited)» не должна становиться заменой"
            )
        }
    }

    func testВыученнаяПравкаРечиНеПеределываетБудущиеДиктовки() {
        // Цена ошибки, ради которой фильтр и существует: одна правка «the» →
        // «a» переписывала каждую следующую диктовку.
        let learned = CorrectionLearning.propose(
            original: "please send me the file",
            edited: "please send me a file"
        )
        let text = TextPipeline(replacements: learned).process("The report is on the desk").text

        XCTAssertEqual(text, "The report is on the desk")
    }

    func testПравкаРегистраНаГраницеПредложенияНеУчится() {
        // Перестановка заглавных при переносе слов внутри абзаца давала пару
        // «The» → «the» вместе с её противоположностью «the» → «The»: два
        // правила, спорящих друг с другом в каждой будущей диктовке.
        let proposals = CorrectionLearning.propose(
            original: "The file is ready. the build passed.",
            edited: "the file is ready. The build passed."
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testОднобуквеннаяЗаменаНеУчится() {
        // Смена письменности формально есть, термина — нет, а замена по всему
        // тексту стоит дороже любой пользы.
        let proposals = CorrectionLearning.propose(original: "привет мир", edited: "привет a")

        XCTAssertTrue(proposals.isEmpty)
    }

    func testБрендРегистрВнутриСловаУчитсяИБезСменыПисьменности() {
        // Единственный признак термина, который работает в тексте целиком на
        // латинице: заглавная не в начале слова.
        for (spoken, written) in [("api", "API"), ("iphone", "iPhone"), ("mac os", "macOS")] {
            let proposals = CorrectionLearning.propose(
                original: "open \(spoken) now",
                edited: "open \(written) now"
            )
            XCTAssertEqual(proposals.map(\.written), [written], "«\(spoken)» → «\(written)»")
        }
    }

    func testОднаИТаЖеПараПредлагаетсяОдинРаз() {
        let proposals = CorrectionLearning.propose(
            original: "открой сентри и закрой сентри",
            edited: "открой Sentry и закрой Sentry"
        )

        XCTAssertEqual(proposals.count, 1, "Дубликат в словаре человеку придётся удалять отдельно")
        XCTAssertEqual(proposals.map(\.spoken), ["сентри"])
    }

    func testПереписанныйТекстНеУчитНичему() {
        // Не правка терминов, а другой текст: якорные слова на месте, а между
        // ними подменено всё. Установить разом столько молчаливых правил
        // необратимо — честнее не выучить ничего.
        var original = ""
        var edited = ""
        for index in 0..<40 {
            original += "слово\(index) sep "
            edited += "Term\(index)X sep "
        }

        XCTAssertTrue(CorrectionLearning.propose(original: original, edited: edited).isEmpty)
    }

    func testПравкаНесколькихТерминовВПределахЛимитаУчится() {
        // Граница должна пропускать настоящую правку: пять терминов подряд —
        // всё ещё правка, а не подмена текста.
        var original = ""
        var edited = ""
        for index in 0..<CorrectionLearning.maximumProposalsPerCorrection {
            original += "термин\(index) sep "
            edited += "Term\(index)X sep "
        }

        XCTAssertEqual(
            CorrectionLearning.propose(original: original, edited: edited).count,
            CorrectionLearning.maximumProposalsPerCorrection
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
