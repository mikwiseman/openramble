import LocalASR
import XCTest

/// Объединение состояний двух моделей в одно, которое видит человек.
///
/// Для человека распознавание и подсказчик терминов — одна «модель»: одна
/// кнопка, один прогресс, одна судьба. Правила объединения — чистая политика,
/// и каждое из них здесь зафиксировано.
final class ModelPairStateTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/engine")

    private func combined(_ main: ModelState, _ vocabulary: ModelState) -> ModelState {
        ModelPairState.combine(
            main: main,
            vocabulary: vocabulary,
            mainTotalBytes: 480,
            vocabularyTotalBytes: 100,
            mainFileCount: 21,
            vocabularyFileCount: 16
        )
    }

    func testОбеГотовыДаютReadyСПапкойОсновной() {
        let state = combined(.ready(directory: directory), .ready(directory: URL(fileURLWithPath: "/tmp/ctc")))

        XCTAssertEqual(state, .ready(directory: directory))
    }

    func testБезПодсказчикаМодельНеСчитаетсяУстановленной() {
        // Добор после обновления приложения: основная уже стоит, подсказчика
        // ещё нет. Для человека это «модель не готова, доскачайте остаток».
        let state = combined(.ready(directory: directory), .notInstalled)

        XCTAssertEqual(state, .notInstalled)
    }

    func testЗагрузкаОсновнойПоказываетОбщийОбъём() {
        let state = combined(.downloading(receivedBytes: 50, totalBytes: 480), .notInstalled)

        XCTAssertEqual(state, .downloading(receivedBytes: 50, totalBytes: 580))
    }

    func testЗагрузкаПодсказчикаПродолжаетОбщийПрогресс() {
        // Основная уже скачана: прогресс не имеет права прыгнуть назад к нулю.
        let state = combined(
            .ready(directory: directory),
            .downloading(receivedBytes: 30, totalBytes: 100)
        )

        XCTAssertEqual(state, .downloading(receivedBytes: 510, totalBytes: 580))
    }

    func testПроверкаОсновнойСчитаетсяОтОбщегоЧислаФайлов() {
        let state = combined(.verifying(checked: 3, total: 21), .notInstalled)

        XCTAssertEqual(state, .verifying(checked: 3, total: 37))
    }

    func testПроверкаПодсказчикаПродолжаетСчётФайлов() {
        let state = combined(.ready(directory: directory), .verifying(checked: 3, total: 16))

        XCTAssertEqual(state, .verifying(checked: 24, total: 37))
    }

    func testОшибкаЛюбойИзМоделейВиднаЦеликом() {
        let failure = ModelStoreError.download("оборвалось")
        XCTAssertEqual(combined(.failed(failure), .notInstalled), .failed(failure))
        XCTAssertEqual(combined(.ready(directory: directory), .failed(failure)), .failed(failure))
    }

    func testRepairЛюбойИзМоделейТребуетRepairОбщий() {
        let state = combined(.ready(directory: directory), .repairRequired("checksums didn't match"))

        guard case let .repairRequired(detail) = state else {
            return XCTFail("Ожидался repairRequired, пришло: \(state)")
        }
        XCTAssertTrue(detail.contains("vocabulary helper"), "Причина обязана назвать виновника: \(detail)")
        XCTAssertTrue(detail.contains("checksums didn't match"))
    }

    func testУдалениеЛюбойВидноКакУдаление() {
        XCTAssertEqual(combined(.deleting, .ready(directory: directory)), .deleting)
        XCTAssertEqual(combined(.ready(directory: directory), .deleting), .deleting)
    }

    func testОставшиесяМегабайтыДляКнопки() {
        // Кнопка обязана называть настоящий объём: полный для чистой установки,
        // только остаток — для добора.
        XCTAssertEqual(
            ModelPairState.remainingBytes(
                main: .notInstalled, vocabulary: .notInstalled,
                mainTotalBytes: 480, vocabularyTotalBytes: 100
            ),
            580
        )
        XCTAssertEqual(
            ModelPairState.remainingBytes(
                main: .ready(directory: directory), vocabulary: .notInstalled,
                mainTotalBytes: 480, vocabularyTotalBytes: 100
            ),
            100
        )
        XCTAssertEqual(
            ModelPairState.remainingBytes(
                main: .ready(directory: directory), vocabulary: .repairRequired("x"),
                mainTotalBytes: 480, vocabularyTotalBytes: 100
            ),
            100
        )
    }
}
