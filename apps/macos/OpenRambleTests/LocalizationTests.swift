import Foundation
import Observation
import XCTest

final class LocalizationTests: XCTestCase {
    func testFreshInstallDefaultsToEnglishEvenOnARussianMac() {
        withDefaults { defaults, suite in
            defaults.set(["ru"], forKey: "AppleLanguages")
            XCTAssertEqual(L10n(suiteName: suite).language, .english)
            defaults.set("unsupported", forKey: L10n.preferenceKey)
            XCTAssertEqual(L10n(suiteName: suite).language, .english)
        }
    }

    func testLanguageChoicePersistsAndCanSwitchBack() {
        withDefaults { defaults, suite in
            let preference = L10n(suiteName: suite)
            preference.language = .russian
            XCTAssertEqual(L10n(suiteName: suite).language, .russian)
            XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ru"])
            preference.language = .english
            XCTAssertEqual(L10n(suiteName: suite).language, .english)
        }
    }

    func testChangingTheLanguageInvalidatesObservedText() {
        withDefaults { _, suite in
            let preference = L10n(suiteName: suite)
            let changed = expectation(description: "Views observe the selected language")
            withObservationTracking {
                _ = preference.language
            } onChange: {
                changed.fulfill()
            }
            preference.language = .russian
            wait(for: [changed], timeout: 1)
        }
    }

    func testInterpolationKeepsUserTextVerbatim() {
        XCTAssertEqual(L10n.tr("Key %@", "42", language: .russian), "Клавиша 42")
        XCTAssertEqual(L10n.tr("Couldn't start recording: %@", "100% / Пример", language: .russian),
                       "Не удалось начать запись: 100% / Пример")
        XCTAssertEqual(L10n.tr("Settings", language: .english), "Settings")
    }

    func testSwitchingLanguagesKeepsRecordingPathsAndRefreshesPlaceholders() throws {
        let original = L10n.shared.language
        defer { L10n.shared.language = original }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        L10n.shared.language = .english
        let directory = try paths.recordings()
        XCTAssertEqual(RecordingsPlaceholder.emptyLibrary.title, "No recordings yet")
        L10n.shared.language = .russian
        XCTAssertEqual(try paths.recordings(), directory)
        XCTAssertEqual(directory.lastPathComponent, "Recordings")
        XCTAssertEqual(RecordingsPlaceholder.emptyLibrary.title, "Записей пока нет")
        L10n.shared.language = .english
        XCTAssertEqual(RecordingsPlaceholder.emptyLibrary.title, "No recordings yet")
    }

    func testRussianResourcesShipInTheApplication() throws {
        XCTAssertEqual(L10n.tr("Settings", language: .russian), "Настройки")
        XCTAssertEqual(L10n.tr("Recordings", language: .russian), "Записи")
        XCTAssertEqual(L10n.tr("Microphone", language: .russian), "Микрофон")
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "ru", ofType: "lproj"))
        let russian = try XCTUnwrap(Bundle(path: path))
        XCTAssertTrue(russian.localizedString(forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist")
            .contains("нужен микрофон"))
    }

    private func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let suite = "OpenRamble.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, suite)
    }
}
