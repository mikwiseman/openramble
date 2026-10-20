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

    func testFailureReasonIsACaseNameThatSurvivesExport() throws {
        let log = DictationLogFile(directory: root, enabled: true)
        log.record(.dictationFailed, failureReason: .microphoneRevoked)
        log.record(.dictationFailed)
        let saved = log.snapshot()
        let lines = saved.data.split(separator: 10).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertFalse(saved.incomplete)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"failureReason\":\"microphoneRevoked\""))
        XCTAssertFalse(lines[1].contains("failureReason"), "an older line without one still exports")

        // A value outside the allowlist cannot be smuggled in through the file.
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let tampered = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "microphoneRevoked", with: "PRIVATE_CANARY")
        try Data(tampered.utf8).write(to: file)
        let reread = log.snapshot()
        XCTAssertTrue(reread.incomplete)
        XCTAssertFalse(String(decoding: reread.data, as: UTF8.self).contains("PRIVATE_CANARY"))
    }

    func testFailureStageAndRecoveredStreamErrorStayPrivateAndSurviveExport() throws {
        let log = DictationLogFile(directory: root, enabled: true)
        log.record(.dictationStageFailed, milliseconds: 10001, stage: .captureFreeze, timedOut: true)
        log.recordFallback(.segmentFailed,
            error: ASREngineError.inferenceFailed("PRIVATE_CANARY /Users/private/take.wav", code: -7))
        let saved = log.snapshot()
        let text = String(decoding: saved.data, as: UTF8.self)
        XCTAssertFalse(saved.incomplete)
        XCTAssertTrue(text.contains("\"stage\":\"captureFreeze\""))
        XCTAssertTrue(text.contains("\"timedOut\":true"))
        XCTAssertTrue(text.contains("\"fallbackReason\":\"segmentFailed\""))
        XCTAssertTrue(text.contains("\"errorCode\":-7"))
        XCTAssertFalse(text.contains("PRIVATE_CANARY"))
        XCTAssertFalse(text.contains("/Users/"))
    }

    /// How long the microphone took to deliver its first frame, and how long
    /// key-up took to reach the ⌘V, are numbers every take already measured
    /// and the journal threw away. Numbers only: nothing of the take itself.
    func testCompletedDictationRecordsMicrophoneStartupAndPaste() throws {
        let phases = DictationPhaseBreakdown(
            captureFreeze: .milliseconds(12),
            enginePreparation: .milliseconds(3),
            recognition: .milliseconds(150),
            engineProcessing: .milliseconds(140),
            audioDuration: .seconds(4)
        )
        let measured = try XCTUnwrap(DictationLogFile.Recognition(report: DictationSpeedReport(
            toRecognizedText: .milliseconds(170),
            toPasteDispatched: .milliseconds(190),
            microphoneStartup: .milliseconds(212),
            phases: phases
        )))
        let unmeasured = try XCTUnwrap(DictationLogFile.Recognition(report: DictationSpeedReport(
            toRecognizedText: .milliseconds(170),
            phases: phases
        )))
        XCTAssertNil(
            DictationLogFile.Recognition(report: DictationSpeedReport(toRecognizedText: .milliseconds(170))),
            "a report without its breakdown records no recognition, as before"
        )

        let log = DictationLogFile(directory: root, enabled: true)
        log.record(.dictationCompleted, milliseconds: 170, recognition: measured)
        log.record(.dictationCompleted, milliseconds: 170, recognition: unmeasured)
        let saved = log.snapshot()
        XCTAssertFalse(saved.incomplete)
        let lines = saved.data.split(separator: 10).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"microphoneStartupMilliseconds\":212"), lines[0])
        XCTAssertTrue(lines[0].contains("\"pasteMilliseconds\":190"), lines[0])
        XCTAssertTrue(lines[0].contains("\"preparationMilliseconds\":3"), lines[0])
        XCTAssertFalse(lines[1].contains("microphoneStartupMilliseconds"), lines[1])
        XCTAssertFalse(lines[1].contains("pasteMilliseconds"), lines[1])
    }
}
