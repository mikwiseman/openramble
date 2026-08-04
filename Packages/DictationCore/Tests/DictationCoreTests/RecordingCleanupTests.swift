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
    ///
    /// Прервать умеет только незакрытую запись, как настоящий: после
    /// `stopRecording` файл уже закрыт и отдан наружу, и удалять его теперь
    /// некому, кроме владельца сессии.
    private final class FileCapture: AudioCapturing, @unchecked Sendable {
        let directory: URL
        let duration: TimeInterval
        private(set) var lastFile: URL?
        private var isRecording = false

        init(directory: URL, duration: TimeInterval = 3.0) {
            self.directory = directory
            self.duration = duration
        }

        func startRecording() async throws -> URL {
            let url = directory.appending(path: "take-\(UUID().uuidString).wav")
            try Data("звук".utf8).write(to: url)
            lastFile = url
            isRecording = true
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            guard let lastFile, isRecording else { throw AudioCaptureError.notRecording }
            isRecording = false
            return (lastFile, duration)
        }

        func abortRecording() async {
            guard isRecording, let lastFile else { return }
            isRecording = false
            try? FileManager.default.removeItem(at: lastFile)
        }
    }

    // Асинхронные варианты, а не `setUpWithError`: тот вызывается вне главного
    // актора, а класс к нему привязан — обращение к `directory` пересекало бы
    // границу изоляции. Сейчас это предупреждение, но каталог при этом уже
    // читается не оттуда, откуда пишется.
    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "takes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
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
        transcribeDelay: Duration = .zero,
        insertError: TextInsertionError? = nil,
        recordingRecovery: any RecordingRecoveryStoring = DiscardingRecordingRecovery()
    ) -> DictationController {
        let inserter = FakeInserter()
        if let insertError {
            Task { await inserter.setError(insertError) }
        }
        return DictationController(
            capture: capture,
            transcribe: { _ in
                if transcribeDelay > .zero { try await Task.sleep(for: transcribeDelay) }
                if let transcribeError { throw transcribeError }
                return ASRResult(text: "распознано", audioDuration: 3, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            recordingRecovery: recordingRecovery
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

    func testRecordingIsPreservedWhenRecognitionFails() async throws {
        // При сбое ASR WAV — единственный путь повторить диктовку без потери.
        let capture = FileCapture(directory: directory)
        let recovered = directory.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        let controller = makeController(
            capture: capture,
            transcribeError: ASREngineError.inferenceFailed("сбой"),
            recordingRecovery: RecordingRecoveryStore(directory: recovered)
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let recordings = try FileManager.default.contentsOfDirectory(
            at: recovered,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recordings.filter { $0.pathExtension == "wav" }.count, 1)
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

    func testAccidentalTapLeavesNoRecording() async throws {
        // Случайное касание клавиши: распознавать нечего — и именно поэтому
        // запись легко забыть. Файл при этом настоящий, с голосом, и лежит он
        // до следующего запуска приложения, которое живёт в меню неделями.
        let capture = FileCapture(directory: directory, duration: 0.1)
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "Слишком короткая запись тоже удаляется: \(leftovers)")
    }

    func testRecordingIsDeletedWhenCancelledDuringTranscription() async throws {
        // Отмена приходит, когда запись уже закрыта и лежит на диске: прервать
        // тут нечего, а удалить — обязательно.
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture, transcribeDelay: .milliseconds(800))

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        // Момент «распознавание идёт» ловится опросом: фиксированный сон на
        // перегруженном CI-runner спит дольше всего распознавания целиком.
        for _ in 0..<400 where controller.state != .transcribing {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        for _ in 0..<400 {
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            if entries.isEmpty, controller.state == .idle { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "Отмена во время распознавания не оставляет голос на диске: \(leftovers)")
    }
}
