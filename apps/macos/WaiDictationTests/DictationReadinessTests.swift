import Foundation
import LocalASR
import XCTest

/// Что человек услышит в ответ на нажатие клавиши, которое ничего не начнёт.
///
/// Молчание в ответ на нажатие неотличимо от сломанного приложения. Каждая
/// причина обязана называться словами, и проверяется это таблицей.
final class DictationReadinessTests: XCTestCase {
    private func reason(
        accessibility: Bool = true,
        microphone: Bool = true,
        model: ModelState = .ready(directory: URL(fileURLWithPath: "/tmp/engine")),
        engineReady: Bool = true
    ) -> String? {
        DictationReadiness.reason(
            accessibilityGranted: accessibility,
            microphoneGranted: microphone,
            modelState: model,
            isEngineReady: engineReady
        )
    }

    func testВПолнойГотовностиОбъяснятьНечего() {
        XCTAssertNil(reason())
    }

    /// Окно прогрева — то самое место, где раньше было глухое молчание: всё
    /// установлено, всё выдано, а клавиша не работает ещё десятки секунд.
    func testПрогревНазываетСебяИСрок() {
        let message = reason(engineReady: false)

        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("20–40 seconds") == true, "без срока непонятно, ждать или перезапускать")
    }

    func testНетМикрофонаНазываетМикрофон() {
        XCTAssertEqual(
            reason(microphone: false),
            "Dictation needs microphone access. Open Settings → General → Permissions."
        )
    }

    func testНетДоступаУниверсальногоДоступаНазываетЕго() {
        XCTAssertTrue(reason(accessibility: false)?.contains("Accessibility") == true)
    }

    func testМодельНеУстановленаНазываетМодель() {
        XCTAssertTrue(reason(model: .notInstalled)?.contains("model isn't downloaded") == true)
    }

    func testИдущаяЗагрузкаНеПутаетсяСОтсутствиемМодели() {
        XCTAssertEqual(
            reason(model: .downloading(receivedBytes: 10, totalBytes: 100)),
            "The recognition model is still downloading."
        )
    }

    func testПоломаннаяМодельЗовётВРемонтАНеВЗагрузку() {
        XCTAssertTrue(reason(model: .repairRequired("checksum"))?.contains("needs repair") == true)
        XCTAssertTrue(reason(model: .failed(.cancelled))?.contains("needs repair") == true)
    }

    /// Разрешения важнее модели: без них не поможет никакая модель, и звать
    /// человека качать полгигабайта раньше, чем он выдал микрофон, — враньё.
    func testРазрешенияНазываютсяРаньшеМодели() {
        let message = reason(microphone: false, model: .notInstalled)

        XCTAssertTrue(message?.contains("microphone") == true)
        XCTAssertFalse(message?.contains("model") == true)
    }

    /// Готовая модель без прогретого движка — не «модель не установлена».
    func testГотоваяМодельНеОбъявляетсяНеустановленной() {
        let message = reason(model: .ready(directory: URL(fileURLWithPath: "/tmp/engine")), engineReady: false)

        XCTAssertFalse(message?.contains("isn't downloaded") == true)
    }
}
