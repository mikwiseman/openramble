import XCTest
import DictationCore

final class DictationLogFileTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testEnabledByDefaultAndWritesSurviveReopening() throws {
        XCTAssertTrue(SettingsDefaults.detailedLogging)
        let log = DictationLogFile(directory: root, enabled: true)
        log.record(.dictationListening)
        let saved = log.snapshot()
        XCTAssertFalse(saved.incomplete)
        XCTAssertTrue(String(decoding: saved.data, as: UTF8.self).contains("dictationListening"))
        let reopened = DictationLogFile(directory: root, enabled: true)
        XCTAssertEqual(reopened.snapshot().data, saved.data)
    }

    func testOptOutCreatesNothingAndClearsEarlierEvents() throws {
        let log = DictationLogFile(directory: root, enabled: false)
        log.record(.appLaunched)
        XCTAssertTrue(log.snapshot().data.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        log.isEnabled = true
        log.record(.appLaunched)
        XCTAssertFalse(log.snapshot().data.isEmpty)
        log.isEnabled = false
        log.record(.dictationListening)
        XCTAssertTrue(log.snapshot().data.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testSevenDayAndTotalByteLimitsKeepNewestCompleteEntries() throws {
        let now = Date()
        let log = DictationLogFile(directory: root, enabled: true, maxBytes: 1000)
        log.record(.engineFailed, at: now.addingTimeInterval(-8 * 86400))
        for i in 0..<100 { log.record(.dictationListening, milliseconds: i, at: now) }
        log.record(.appTerminationReady, at: now)
        let saved = log.snapshot(at: now)
        XCTAssertLessThanOrEqual(saved.data.count, 1000)
        XCTAssertFalse(String(decoding: saved.data, as: UTF8.self).contains("engineFailed"))
        XCTAssertTrue(String(decoding: saved.data, as: UTF8.self).contains("appTerminationReady"))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, 1000)
        XCTAssertFalse(saved.incomplete)
    }

    func testExportReencodesKnownFieldsAndSkipsInterruptedWrites() throws {
        let log = DictationLogFile(directory: root, enabled: true)
        log.record(.dictationListening)
        _ = log.snapshot()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"event\":", with: "\"private\":\"PRIVATE_CANARY\",\"event\":")
        text += "{\"partial\":\"PRIVATE_CANARY"
        try Data(text.utf8).write(to: file)
        let saved = log.snapshot()
        XCTAssertTrue(saved.incomplete)
        XCTAssertFalse(String(decoding: saved.data, as: UTF8.self).contains("PRIVATE_CANARY"))
        XCTAssertTrue(String(decoding: saved.data, as: UTF8.self).contains("dictationListening"))
    }

    func testConcurrentWritersProduceCompleteEntries() async throws {
        let log = DictationLogFile(directory: root, enabled: true)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 { group.addTask { log.record(.dictationCompleted, milliseconds: i) } }
        }
        let saved = log.snapshot()
        XCTAssertEqual(saved.data.split(separator: 10).count, 100)
        XCTAssertFalse(saved.incomplete)
    }

    func testRecognitionFailureKeepsNativeCodeWithoutErrorText() throws {
        let log = DictationLogFile(directory: root, enabled: true)
        log.recordRecognitionFailure(ASREngineError.inferenceFailed("PRIVATE_CANARY /Users/someone/take.wav", code: -7))
        log.recordRecognitionFailure(ASREngineError.unsupportedAudioFormat("PRIVATE_CANARY"))
        let saved = log.snapshot()
        let text = String(decoding: saved.data, as: UTF8.self)
        XCTAssertTrue(text.contains("recognitionEngineFailed"))
        XCTAssertTrue(text.contains("\"errorCode\":-7"))
        XCTAssertTrue(text.contains("recognitionAudioInvalid"))
        XCTAssertFalse(text.contains("PRIVATE_CANARY"))
        XCTAssertFalse(text.contains("/Users/"))
    }

    func testRecognitionTimingsSurviveExportAlongsideOlderEntries() throws {
        let log = DictationLogFile(directory: root, enabled: true)
        log.record(.appLaunched)
        log.record(.dictationCompleted, milliseconds: 52000,
            recognition: .init(audioMilliseconds: 480000, engineMilliseconds: 51900,
                               decodingMilliseconds: 50, streamedSegments: 23, fileBacked: true))
        let saved = log.snapshot()
        let text = String(decoding: saved.data, as: UTF8.self)
        XCTAssertFalse(saved.incomplete)
        XCTAssertEqual(saved.data.split(separator: 10).count, 2)
        XCTAssertTrue(text.contains("\"streamedSegments\":23"))
        XCTAssertTrue(text.contains("\"engineMilliseconds\":51900"))
        XCTAssertTrue(text.contains("\"fileBacked\":true"))
        XCTAssertNil(DictationLogFile.milliseconds(.infinity))
        XCTAssertNil(DictationLogFile.milliseconds(.nan))
    }
}
