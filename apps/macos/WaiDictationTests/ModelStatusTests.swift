import LocalASR
import XCTest

/// Что человек видит про модель в каждом её состоянии.
///
/// Состояний шесть, экрана два, и раньше все шесть были расписаны в обоих
/// местах руками. Проверяется здесь именно видимое: заголовок, объяснение,
/// подпись индикатора и набор кнопок.
final class ModelStatusTests: XCTestCase {
    private let ready = ModelState.ready(directory: URL(fileURLWithPath: "/tmp/model"))

    private func status(
        _ state: ModelState,
        preparing: Bool = false,
        place: ModelStatus.Place = .settings
    ) -> ModelStatus {
        ModelStatus.make(state: state, isPreparingEngine: preparing, place: place)
    }

    // MARK: - Состояния

    func testНеУстановленаПредлагаетСкачатьИНазываетРазмер() {
        let status = status(.notInstalled)

        XCTAssertEqual(status.title, "Модель не установлена")
        XCTAssertEqual(status.actions, [.install])
        XCTAssertEqual(status.detail?.contains("483 МБ"), true)
        XCTAssertNil(status.progress)
    }

    func testЗагрузкаПоказываетМегабайтыИДолю() {
        let status = status(.downloading(receivedBytes: 120_000_000, totalBytes: 483_000_000))

        XCTAssertEqual(status.title, "Скачиваю модель…")
        XCTAssertEqual(status.progressLabel, "120 из 483 МБ")
        XCTAssertEqual(status.progress ?? 0, 0.248, accuracy: 0.01)
        // Единственное действие — честно остановить загрузку и удалить partial.
        XCTAssertEqual(status.actions, [.cancel])
        XCTAssertEqual(status.announcement, "Скачиваю модель, 120 из 483 МБ")
    }

    func testПроверкаНазываетНомерФайла() {
        let status = status(.verifying(checked: 3, total: 12))

        XCTAssertEqual(status.title, "Проверяю скачанное…")
        XCTAssertEqual(status.progressLabel, "Файл 3 из 12")
        XCTAssertEqual(status.progress ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(status.actions, [])
    }

    func testГотоваяМодельВНастройкахДаётЕёУдалить() {
        let status = status(ready, place: .settings)

        XCTAssertEqual(status.title, "Модель готова")
        XCTAssertEqual(status.tone, .success)
        XCTAssertEqual(status.actions, [.delete])
    }

    /// В онбординге кнопки удаления нет.
    ///
    /// Человек ставит приложение первый раз; предложить снести только что
    /// скачанные 483 МБ — единственное, чего ему сейчас точно не надо.
    func testГотоваяМодельВОнбордингеНеПредлагаетУдаление() {
        XCTAssertEqual(status(ready, place: .onboarding).actions, [])
    }

    func testПрогревДвижкаОбъясняетЗадержкуПервогоРаза() {
        let status = status(ready, preparing: true)

        XCTAssertEqual(status.title, "Модель готова")
        XCTAssertEqual(status.detail?.contains("первому запуску"), true)
        XCTAssertEqual(status.announcement, "Модель готова, готовлю к первому запуску")
    }

    func testОшибкаПредлагаетПовторить() {
        let status = status(.failed(.download("сервер не ответил")))

        XCTAssertEqual(status.title, "Не удалось установить модель")
        XCTAssertEqual(status.tone, .failure)
        XCTAssertEqual(status.actions, [.retry])
        XCTAssertEqual(status.detail, "Не удалось скачать: сервер не ответил")
    }

    func testПовреждённаяМодельТребуетЯвногоВосстановления() {
        let status = status(.repairRequired("не сошлась контрольная сумма"))

        XCTAssertEqual(status.title, "Модель требует восстановления")
        XCTAssertEqual(status.actions, [.repair])
        XCTAssertEqual(ModelStatus.Action.repair.title, "Скачать модель заново — 483 МБ")
        XCTAssertEqual(status.detail?.contains("повреждена"), true)
    }

    func testУдалениеПоказываетсяОтдельно() {
        let status = status(.deleting)

        XCTAssertEqual(status.title, "Удаляю модель…")
        XCTAssertEqual(status.actions, [])
        XCTAssertNil(status.progress)
    }

    // MARK: - Ошибки словами

    /// Нехватка места объяснялась дампом перечисления с сырыми байтами.
    ///
    /// Человек видел `notEnoughDiskSpace(requiredBytes: 594…, availableBytes: 1…)`
    /// и должен был сам догадаться, что на диске нет места.
    func testНехваткаМестаНазываетсяСловамиИВМегабайтах() {
        let text = ModelStatus.message(
            for: .notEnoughDiskSpace(requiredBytes: 594_000_000, availableBytes: 120_000_000)
        )

        XCTAssertEqual(
            text,
            "На диске не хватает места: нужно 594 МБ, свободно 120 МБ."
        )
        XCTAssertFalse(text.contains("requiredBytes"))
    }

    func testУНикакойОшибкиНетСырогоПеречисления() {
        let errors: [ModelStoreError] = [
            .manifest("битый json"),
            .download("нет сети"),
            .verification("не сошлась сумма"),
            .install("нет прав"),
            .repairRequired("нет marker"),
            .importSource("не та папка"),
            .notEnoughDiskSpace(requiredBytes: 1, availableBytes: 0),
            .cancelled,
        ]

        for error in errors {
            let text = ModelStatus.message(for: error)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(
                text.contains("("),
                "«\(text)» выглядит как дамп перечисления, а не как объяснение"
            )
        }
    }

    // MARK: - Объявления

    func testКаждоеСостояниеОбъявляетСебяГолосом() {
        let states: [ModelState] = [
            .notInstalled,
            .downloading(receivedBytes: 0, totalBytes: 483_000_000),
            .verifying(checked: 0, total: 12),
            ready,
            .repairRequired("повреждена"),
            .failed(.cancelled),
            .deleting,
        ]

        var announcements: Set<String> = []
        for state in states {
            let announcement = status(state).announcement
            XCTAssertFalse(announcement.isEmpty)
            announcements.insert(announcement)
        }
        XCTAssertEqual(announcements.count, states.count, "состояния не должны звучать одинаково")
    }

    // MARK: - Подсказки к кнопкам

    func testУКаждойКнопкиЕстьПодсказка() {
        for action in [ModelStatus.Action.install, .retry, .repair, .delete] {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.hint.isEmpty)
        }
        // Удаление — единственное необратимое действие на экране, и о его цене
        // надо сказать до нажатия.
        XCTAssertEqual(ModelStatus.Action.delete.hint.contains("перестанет работать"), true)
    }
}
