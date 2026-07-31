import XCTest
@testable import DictationCore

/// Запись голоса не должна оставаться на диске после того, как текст распознан.
///
/// Дефект, который эти тесты стерегут, был настоящим: файлы не удалялись
/// никогда. Полчаса диктовки в день — это около двадцати гигабайт за год и,
/// что важнее, архив всего сказанного вслух у продукта, который обещает
/// приватность.
@MainActor
final class RecordingCleanupTests: XCTestCase {
    private var directory: URL!

    /// Захват, который создаёт настоящий файл — иначе проверять нечего.
    private final class FileCapture: AudioCapturing, @unchecked Sendable {
        let directory: URL
        private(set) var lastFile: URL?

        init(directory: URL) { self.directory = directory }

        func startRecording() async throws -> URL {
            let url = directory.appending(path: "take-\(UUID().uuidString).wav")
            try Data("звук".utf8).write(to: url)
            lastFile = url
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            guard let lastFile else { throw AudioCaptureError.notRecording }
            return (lastFile, 3.0)
        }

        func abortRecording() async {
            if let lastFile { try? FileManager.default.removeItem(at: lastFile) }
        }
    }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "takes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settle(_ iterations: Int = 15) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeController(
        capture: FileCapture,
        transcribeError: Error? = nil,
        insertError: TextInsertionError? = nil
    ) -> DictationController {
        let inserter = FakeInserter()
        if let insertError {
            Task { await inserter.setError(insertError) }
        }
        return DictationController(
            capture: capture,
            transcribe: { _ in
                if let transcribeError { throw transcribeError }
                return ASRResult(text: "распознано", audioDuration: 3, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            recovery: FakeRecovery()
        )
    }

    func testRecordingIsDeletedAfterSuccessfulInsertion() async throws {
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "После вставки запись голоса должна быть удалена: \(leftovers)")
    }

    func testRecordingIsDeletedWhenRecognitionFails() async throws {
        // Сбой распознавания — не повод хранить голос.
        let capture = FileCapture(directory: directory)
        let controller = makeController(
            capture: capture,
            transcribeError: ASREngineError.inferenceFailed("сбой")
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "После ошибки распознавания запись тоже удаляется: \(leftovers)")
    }

    func testRecordingIsDeletedWhenInsertionFails() async throws {
        // Текст сохранён отдельным файлом, а сам голос хранить незачем.
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture, insertError: .accessibilityPermissionDenied)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "После неудачной вставки запись удаляется: \(leftovers)")
    }

    func testRecordingIsDeletedOnCancel() async throws {
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.cancel()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "Отменённая диктовка не оставляет записи: \(leftovers)")
    }
}
