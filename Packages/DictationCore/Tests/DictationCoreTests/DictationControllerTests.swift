import XCTest
@testable import DictationCore

// MARK: - Подставные края системы

actor FakeCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    private var startError: AudioCaptureError?
    private let file = URL(fileURLWithPath: "/tmp/fake-take.wav")

    func setStartError(_ error: AudioCaptureError?) { startError = error }

    func startRecording() async throws -> URL {
        startCount += 1
        if let startError { throw startError }
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        return (file, 2.0)
    }

    func abortRecording() async { abortCount += 1 }
}

/// Захват, у которого первый кадр звука приходит не сразу, как у настоящего.
///
/// Настоящий движок возвращается из `startRecording` на запуске, а слышать
/// начинает примерно через 0,13 с. Всё, что происходит в этот зазор,
/// подставной захват без задержки скрывал полностью.
actor SlowFirstFrameCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    /// `nil` — устройство молчит и кадра не будет вовсе (AirPods в ящике).
    private let firstFrame: Gate?
    private let file = URL(fileURLWithPath: "/tmp/slow-first-frame.wav")

    init(firstFrame: Gate?) { self.firstFrame = firstFrame }

    func startRecording() async throws -> URL {
        startCount += 1
        return file
    }

    func waitForFirstFrame() async -> Bool {
        guard let firstFrame else {
            // Молчащее устройство: ждём, пока запись не закончат снаружи.
            while stopCount == 0, abortCount == 0 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        await firstFrame.pass()
        return true
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        return (file, 2.0)
    }

    func abortRecording() async { abortCount += 1 }
}

actor FakeInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var returnPresses = 0
    private(set) var targets: [TargetApplication?] = []
    private var error: TextInsertionError?
    nonisolated(unsafe) var frontmost: TargetApplication?

    func setError(_ error: TextInsertionError?) { self.error = error }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        if let error { throw error }
        insertedTexts.append(text)
        targets.append(target)
    }

    func pressReturn() async throws {
        if let error { throw error }
        returnPresses += 1
    }

    nonisolated func frontmostApplication() -> TargetApplication? { frontmost }
}

actor FakeOverlay: OverlayPresenting {
    private(set) var presentedStates: [DictationState] = []
    private(set) var dismissCount = 0
    private(set) var notices: [DictationNotice] = []

    func present(_ state: DictationState, elapsed: TimeInterval) async {
        presentedStates.append(state)
    }
    func dismiss() async { dismissCount += 1 }
    func presentNotice(_ notice: DictationNotice) async { notices.append(notice) }
}

actor FakeSounds: Sounding {
    private(set) var startPlays = 0
    private(set) var stopPlays = 0
    func playStart() async { startPlays += 1 }
    func playStop() async { stopPlays += 1 }
}

// MARK: - Тесты

@MainActor
final class DictationControllerTests: XCTestCase {
    private var capture: FakeCapture!
    private var inserter: FakeInserter!
    private var overlay: FakeOverlay!
    private var sounds: FakeSounds!

    override func setUp() async throws {
        capture = FakeCapture()
        inserter = FakeInserter()
        overlay = FakeOverlay()
        sounds = FakeSounds()
    }

    private func makeController(
        recognized: String = "привет мир",
        transcribeDelay: Duration = .zero,
        transcribeError: Error? = nil,
        replacements: [DictionaryReplacement] = []
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in
                if transcribeDelay > .zero { try await Task.sleep(for: transcribeDelay) }
                if let transcribeError { throw transcribeError }
                return ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { TextPipeline(replacements: replacements) }
        )
    }

    /// Дать фоновым задачам контроллера доработать.
    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Обычный путь

    func testFullFlowInsertsProcessedText() async throws {
        let controller = makeController(recognized: "привет мир")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["Привет мир"], "Текст должен пройти через обработку")
        XCTAssertEqual(controller.state, .idle, "После вставки сессия закрыта")
    }

    func testStartSoundPlaysOnlyAfterCaptureIsLive() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)

        // До того как запись пошла, звука быть не должно: иначе пользователь
        // заговорит в ещё не поднятый микрофон.
        let immediatePlays = await sounds.startPlays
        XCTAssertEqual(immediatePlays, 0)

        await settle()

        let playsAfter = await sounds.startPlays
        XCTAssertEqual(playsAfter, 1)
        XCTAssertEqual(controller.state, .listening)
    }

    func testStartSoundWaitsForTheFirstRecordedFrame() async throws {
        // «Говорите» — обещание, что микрофон уже слышит. Движок запускается
        // раньше, чем начинает отдавать кадры: 0,13–0,14 с на M4 Pro
        // (docs/benchmarks.md). Человек, начинающий говорить по сигналу, терял
        // в этот зазор первое слово.
        let frame = Gate()
        let slowCapture = SlowFirstFrameCapture(firstFrame: frame)
        let controller = DictationController(
            capture: slowCapture,
            transcribe: { _ in ASRResult(text: "привет", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        XCTAssertEqual(controller.state, .listening, "Панель показывает запись сразу")
        let beforeFrame = await sounds.startPlays
        XCTAssertEqual(beforeFrame, 0, "Сигнал не звучит, пока микрофон не отдал ни кадра")

        await frame.open()
        await settle()

        let afterFrame = await sounds.startPlays
        XCTAssertEqual(afterFrame, 1, "С первым кадром сигнал обязан прозвучать")
    }

    func testSilentDeviceGivesNoStartSoundAndDoesNotHangTheSession() async throws {
        // Кадров нет вовсе — микрофон выбран не тот. Обещать «говорите» здесь
        // нельзя, но и подвесить сессию ожиданием — тоже: остановка обязана
        // работать, иначе микрофон останется включённым до часового предела.
        let silentCapture = SlowFirstFrameCapture(firstFrame: nil)
        let controller = DictationController(
            capture: silentCapture,
            transcribe: { _ in ASRResult(text: "привет", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)
        let plays = await sounds.startPlays
        XCTAssertEqual(plays, 0, "Молчащее устройство не даёт повода звать говорить")

        controller.stop()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle, "Остановка обязана пройти и без единого кадра")
        let stops = await silentCapture.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testQuickTapStopsWithoutWaitingForTheFirstFrame() async throws {
        // Нажал и отпустил раньше, чем движок услышал: ждать кадра ради звука
        // «говорите» в уже законченной записи незачем, а на молчащем
        // устройстве это ожидание оставило бы микрофон включённым.
        let silentCapture = SlowFirstFrameCapture(firstFrame: nil)
        let controller = DictationController(
            capture: silentCapture,
            transcribe: { _ in ASRResult(text: "привет", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        controller.stop()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle, "Отложенное отпускание не ждёт первого кадра")
        let plays = await sounds.startPlays
        XCTAssertEqual(plays, 0)
    }

    // MARK: Отпускание раньше готовности

    func testReleaseBeforeCaptureStartsIsNotLost() async throws {
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        // Клавишу отпустили, пока движок ещё поднимался — самый частый жест
        // для короткой фразы.
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1, "Отпускание не должно потеряться")
        XCTAssertEqual(controller.state, .idle, "Запись не должна остаться включённой")
    }

    // MARK: Единственность финализации

    func testRepeatedStopInsertsOnlyOnce() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.stop()
        controller.stop()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1, "Текст обязан вставиться ровно один раз")
    }

    func testSecondBeginWhileBusyIsIgnored() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        let starts = await capture.startCount
        XCTAssertEqual(starts, 1, "Вторая сессия поверх занятой не начинается")
    }

    // MARK: Отмена

    func testCancelDuringRecordingNeverInserts() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.cancel()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "После отмены текст не вставляется")
        let aborts = await capture.abortCount
        XCTAssertEqual(aborts, 1, "Запись должна быть прервана, а файл выброшен")
        XCTAssertEqual(controller.state, .idle)
    }

    func testCancelDuringTranscriptionNeverInserts() async throws {
        // Распознавание идёт заметное время — успеваем отменить в середине.
        // Момент «распознавание идёт» ловится опросом: фиксированный сон на
        // перегруженном CI-runner спит дольше всего распознавания целиком.
        let controller = makeController(transcribeDelay: .milliseconds(800))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<400 where controller.state != .transcribing {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.state, .idle)

        let inserted = await inserter.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "Отмена во время распознавания обязана предотвратить вставку")
    }

    // MARK: Ошибки

    func testCaptureFailureSurfacesAndResets() async throws {
        await capture.setStartError(.microphonePermissionDenied)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        XCTAssertEqual(controller.state, .idle)
        let notices = await overlay.notices
        XCTAssertEqual(notices.first?.kind, .failure, "Ошибка должна быть показана, а не проглочена")
    }

    func testRecognitionFailureIsReported() async throws {
        let controller = makeController(transcribeError: ASREngineError.inferenceFailed("сбой"))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        XCTAssertEqual(notices.first?.kind, .failure)
        XCTAssertEqual(controller.state, .idle)
    }

    func testTextStaysInMemoryWhenInsertionFails() async throws {
        // Вставка не удалась — распознанное нельзя терять или писать на диск.
        await inserter.setError(.accessibilityPermissionDenied)
        let controller = makeController(recognized: "важная мысль")

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertEqual(controller.pendingRecovery?.text, "Важная мысль")
    }

    func testSecureInputFailureExplainsItself() async throws {
        // Активное поле пароля — не сбой продукта, и сообщение должно это отражать.
        await inserter.setError(.secureInputActive)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        XCTAssertTrue(
            notices.contains { $0.message.contains("secure input") },
            "Пользователю нужно объяснить, почему текст не вставился"
        )
    }

    func testClipboardRestoreFailureDoesNotClaimInsertedTextWasLost() async throws {
        await inserter.setError(.insertedButClipboardRestoreFailed)
        let controller = makeController(recognized: "текст уже вставлен")

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        XCTAssertNil(controller.pendingRecovery)
        XCTAssertTrue(notices.contains { $0.message.contains("The text was inserted") })
    }

    // MARK: Цель вставки

    func testTargetIsCapturedAtKeyDownNotAtInsertion() async throws {
        let original = TargetApplication(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 1, localizedName: "TextEdit")
        inserter.frontmost = original

        let controller = makeController(transcribeDelay: .milliseconds(60))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        // Пока идёт распознавание, пользователь переключился в другое приложение.
        inserter.frontmost = TargetApplication(bundleIdentifier: "com.apple.Safari", processIdentifier: 2, localizedName: "Safari")
        controller.stop()
        await settle(30)

        let targets = await inserter.targets
        XCTAssertEqual(
            targets.first??.bundleIdentifier,
            "com.apple.TextEdit",
            "Текст должен попасть туда, где его диктовали"
        )
    }

    // MARK: Команда в конце фразы

    func testSafeBetaNeverPressesReturnFromSpeech() async throws {
        let controller = makeController(recognized: "готово отправь")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        let presses = await inserter.returnPresses
        XCTAssertEqual(inserted, ["Готово отправь"])
        XCTAssertEqual(presses, 0, "False trigger не должен отправлять сообщение")
    }

    func testNewLineCommandArrivesAsTextNotAsKeypress() async throws {
        // «Новая строка» обязана дойти до поля ввода переносом. Нажимать Return
        // здесь нельзя: в мессенджере это отправит сообщение.
        let controller = makeController(recognized: "первая строка новая строка")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        let presses = await inserter.returnPresses
        XCTAssertEqual(inserted, ["Первая строка\n"])
        XCTAssertEqual(presses, 0, "Return отправил бы сообщение вместо переноса строки")
    }

    // MARK: Пустой результат

    func testEmptyRecognitionInsertsNothingAndDoesNotError() async throws {
        // Раньше здесь проверялось «ни одного сообщения». Требование было
        // сформулировано как «промолчать — не ошибка», и это верно: ошибкой
        // пустой результат не является. Но молчание оказалось не тем ответом:
        // погасшая панель без текста неотличима от «вставилось в чужое окно»,
        // и человек шёл искать фразу там, где её нет. Проверяем то, что и
        // требовалось: не ошибка, ничего не вставлено, голос не сохранён.
        let controller = makeController(recognized: "   ")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertTrue(
            notices.allSatisfy { $0.kind != .failure },
            "Пустой результат — не сбой: \(notices.map(\.message))"
        )
        XCTAssertTrue(notices.allSatisfy { $0.recoveryAudio == nil })
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Микрофон и уборка

    func testOverlayIsDismissedOnEveryPath() async throws {
        // Успешный путь.
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()
        let afterSuccess = await overlay.dismissCount
        XCTAssertGreaterThan(afterSuccess, 0)

        // Путь с отменой.
        let cancelled = makeController()
        cancelled.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        cancelled.cancel()
        await settle()
        let afterCancel = await overlay.dismissCount
        XCTAssertGreaterThan(afterCancel, afterSuccess, "Индикатор обязан убираться и после отмены")
    }

    func testDisabledOrMissingModelPreventsStart() async throws {
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: false, isModelReady: true)
        await settle(3)
        controller.begin(handsFree: false, isEnabled: true, isModelReady: false)
        await settle(3)

        let starts = await capture.startCount
        XCTAssertEqual(starts, 0, "Без модели или при выключенной диктовке запись не начинается")
    }

    // MARK: Режим громкой связи

    func testHandsFreeIgnoresKeyRelease() async throws {
        let controller = makeController()
        controller.begin(handsFree: true, isEnabled: true, isModelReady: true)
        await settle()

        // В режиме громкой связи отпускание клавиши ничего не значит.
        controller.stop()
        await settle(4)
        XCTAssertEqual(controller.state, .listening, "Запись должна продолжаться")

        controller.stopHandsFree()
        await settle()
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1)
    }
}
