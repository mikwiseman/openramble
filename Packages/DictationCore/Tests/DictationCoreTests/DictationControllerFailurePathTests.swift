import XCTest
@testable import DictationCore

// MARK: - Подставные края, умеющие ломаться по частям

actor ScriptedCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var abortCount = 0
    private var duration: TimeInterval = 2.0
    private let file = URL(fileURLWithPath: "/tmp/scripted-take.wav")

    func setDuration(_ value: TimeInterval) { duration = value }

    func startRecording() async throws -> URL {
        startCount += 1
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        (file, duration)
    }

    func abortRecording() async { abortCount += 1 }
}

/// Вставка и нажатие Return ломаются независимо: это разные системные вызовы,
/// и в жизни второй отказывает при живом первом.
actor ScriptedInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var returnPresses = 0
    private var insertError: TextInsertionError?
    private var returnError: TextInsertionError?
    private var insertDelay: Duration = .zero

    func setInsertError(_ error: TextInsertionError?) { insertError = error }
    func setReturnError(_ error: TextInsertionError?) { returnError = error }
    func setInsertDelay(_ delay: Duration) { insertDelay = delay }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        if insertDelay > .zero { try? await Task.sleep(for: insertDelay) }
        if let insertError { throw insertError }
        insertedTexts.append(text)
    }

    func pressReturn() async throws {
        if let returnError { throw returnError }
        returnPresses += 1
    }

    nonisolated func frontmostApplication() -> TargetApplication? { nil }
}

actor CollectingOverlay: OverlayPresenting {
    private(set) var notices: [DictationNotice] = []
    func present(_ state: DictationState, elapsed: TimeInterval) async {}
    func dismiss() async {}
    func presentNotice(_ notice: DictationNotice) async { notices.append(notice) }
}

actor SilentSounds: Sounding {
    func playStart() async {}
    func playStop() async {}
}

@MainActor
final class StateLog {
    var states: [DictationState] = []
}

// MARK: - Тесты

/// Пути, по которым продукт идёт, когда что-то пошло не так. Именно они решают,
/// доверяет ли человек диктовке: обычный сценарий он видит каждый день, а
/// поведение в сбое — один раз, и запоминает его надолго.
@MainActor
final class DictationControllerFailurePathTests: XCTestCase {
    private var capture: ScriptedCapture!
    private var inserter: ScriptedInserter!
    private var overlay: CollectingOverlay!
    private var transcribeCalls: TranscribeCounter!

    /// Счётчик обращений к распознаванию — замыкание передаётся как `@Sendable`.
    actor TranscribeCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    override func setUp() async throws {
        capture = ScriptedCapture()
        inserter = ScriptedInserter()
        overlay = CollectingOverlay()
        transcribeCalls = TranscribeCounter()
    }

    /// Часы, которые тест двигает сам: ждать час в проверке предела нельзя.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0
        func advance(by seconds: TimeInterval) {
            lock.lock(); offset += seconds; lock.unlock()
        }
        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return Date().addingTimeInterval(offset)
        }
    }

    private func makeController(
        recognized: String = "привет мир",
        allowPressReturnCommand: Bool = false,
        clock: TestClock? = nil
    ) -> DictationController {
        let counter = transcribeCalls!
        return DictationController(
            capture: capture,
            transcribe: { _ in
                await counter.increment()
                return ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: SilentSounds(),
            pipeline: { TextPipeline(allowPressReturnCommand: allowPressReturnCommand) },
            now: { clock?.now ?? Date() }
        )
    }

    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func runFullDictation(_ controller: DictationController) async {
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()
    }

    // MARK: - Нажатие Return

    func testFailedReturnDoesNotPretendTheTextWasLost() async throws {
        // Текст вставился, а Return нажать не вышло — например, пользователь
        // так и держит модификатор. Сказать «текст не вставлен, он сохранён»
        // здесь неправда дважды: текст на месте, и вторая его копия на диске
        // никому не нужна — приватный инструмент не складывает продиктованное
        // без причины.
        await inserter.setReturnError(.modifiersStillHeld)
        let controller = makeController(recognized: "готово отправь", allowPressReturnCommand: true)

        await runFullDictation(controller)

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices

        XCTAssertEqual(inserted, ["Готово"], "Текст обязан остаться вставленным")
        XCTAssertEqual(notices.first?.kind, .warning)
        XCTAssertTrue(
            notices.contains { $0.message.contains("Return") },
            "Сообщение должно объяснять, что не получилось именно нажатие: \(notices)"
        )
        XCTAssertNil(controller.pendingRecovery, "Спасать нечего — текст на месте")
        XCTAssertEqual(controller.state, .idle)
    }

    func testSuccessfulReturnLeavesNoNotice() async throws {
        let controller = makeController(recognized: "готово отправь", allowPressReturnCommand: true)

        await runFullDictation(controller)

        let presses = await inserter.returnPresses
        let notices = await overlay.notices
        XCTAssertEqual(presses, 1)
        XCTAssertTrue(notices.isEmpty, "Удачная диктовка не должна ничего сообщать")
    }

    // MARK: - Спасение текста

    func testInsertionFailureKeepsTextOnlyInMemory() async throws {
        await inserter.setInsertError(.accessibilityPermissionDenied)
        let controller = makeController(recognized: "важная мысль")

        await runFullDictation(controller)

        let notices = await overlay.notices
        XCTAssertEqual(notices.first?.kind, .warning)
        XCTAssertEqual(controller.pendingRecovery?.text, "Важная мысль")
        XCTAssertEqual(controller.state, .idle, "Сессия обязана закрыться в любом случае")
    }

    func testNextDictationKeepsPreviousRecoverableTextUntilExplicitRecovery() async throws {
        await inserter.setInsertError(.accessibilityPermissionDenied)
        let controller = makeController(recognized: "важная мысль")
        await runFullDictation(controller)
        XCTAssertNotNil(controller.pendingRecovery)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)

        XCTAssertEqual(controller.pendingRecovery?.text, "Важная мысль")
    }

    // MARK: - Слишком короткое нажатие

    func testAccidentalTapIsDroppedWithoutBotheringTheEngine() async throws {
        // Задели клавишу — записи нет. Гонять распознавание и тем более пугать
        // человека ошибкой не за что.
        await capture.setDuration(0.1)
        let controller = makeController()

        await runFullDictation(controller)

        let calls = await transcribeCalls.count
        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        XCTAssertEqual(calls, 0, "Распознавать нечего")
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertTrue(notices.isEmpty, "Случайное касание — не повод для сообщения")
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: - Пустой результат

    func testEmptyRecognitionTellsThePersonInsteadOfVanishing() async throws {
        // Человек держал клавишу и говорил, а движок не расслышал ничего:
        // микрофон выбран не тот, вокруг шумно, речь ушла в стол. Панель
        // просто гасла — и это неотличимо от «текст вставился куда-то не
        // туда»: человек идёт искать пропавшую фразу в чужом окне.
        let controller = makeController(recognized: "   ")

        await runFullDictation(controller)

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        XCTAssertTrue(inserted.isEmpty, "Вставлять нечего")
        XCTAssertEqual(notices.count, 1, "Молчать здесь нельзя: \(notices.map(\.message))")
        XCTAssertEqual(notices.first?.kind, .info, "Это не сбой — движок просто не расслышал")
        XCTAssertNil(notices.first?.recoveryAudio, "Голос не остаётся на диске")
        XCTAssertEqual(controller.state, .idle)
    }

    func testEmptyRecognitionAfterCancelStaysSilent() async throws {
        // Отменённая диктовка не объясняется ничем: человек сам её закрыл.
        let controller = makeController(recognized: "   ")

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.cancel()
        await settle(30)

        let notices = await overlay.notices
        XCTAssertTrue(notices.isEmpty, "После отмены сообщать не о чем: \(notices.map(\.message))")
    }

    // MARK: - Отмена в момент вставки

    func testCancelDuringInsertionCannotTakeTheTextBack() async throws {
        // Отмена, нажатая в момент вставки, приходит слишком поздно: событие
        // уже ушло в чужое приложение. Важно, что сессия при этом закрывается
        // корректно, а не остаётся висеть в «вставляю».
        //
        // Момент «вставка идёт» ловится опросом, а не фиксированным сном:
        // на перегруженном CI-runner `Task.sleep(30ms)` спит и две секунды,
        // за которые вставка успевает закончиться целиком.
        await inserter.setInsertDelay(.milliseconds(800))
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<400 where controller.state != .inserting {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .inserting)

        controller.cancel()
        await settle(40)
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["Привет мир"])
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: - Поток состояний

    func testStateChangesArriveOnceAndInOrder() async throws {
        // Интерфейс подписан на состояние, а разрешения опрашиваются раз в
        // секунду. Повтор одного и того же состояния означал бы лишнюю
        // перерисовку окна настроек каждую секунду.
        let controller = makeController()
        let log = StateLog()
        controller.onStateChange = { log.states.append($0) }

        await runFullDictation(controller)

        XCTAssertEqual(log.states, [.preparing, .listening, .transcribing, .inserting, .idle])
    }

    // MARK: - Проверка предела длительности

    func testDurationCheckDoesNothingOutsideRecording() async throws {
        // Таймер тикает каждые пять секунд и обязан молчать, пока записи нет.
        let controller = makeController()

        controller.checkDurationLimit()
        await settle(3)

        let starts = await capture.startCount
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(starts, 0)
    }

    func testHourLimitExplanationReachesTheScreenAfterTheSession() async throws {
        // Запись обрывается на полуслове не человеком и не сбоем, а пределом.
        // Объяснение уходило только подписчику, а его никто не показывает —
        // человек видел, как диктовка кончилась сама, и не узнавал почему.
        // Показать в момент обрыва тоже нельзя: `finish()` тут же перерисует
        // панель под «распознаю», и объяснение живёт доли секунды.
        let clock = TestClock()
        let controller = makeController(clock: clock)
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        // Час прошёл — двигаем часы сессии, а не спим.
        clock.advance(by: DictationDurationPolicy.maximum + 1)
        controller.checkDurationLimit()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        await settle(3)

        let presented = await overlay.notices
        XCTAssertEqual(
            presented.map(\.message),
            ["Reached the one-hour limit. Transcribing what was recorded."],
            "Объяснение обязано дойти до панели — и ровно один раз"
        )
        XCTAssertEqual(presented.first?.kind, .info)
        XCTAssertEqual(notices.count, 1, "Подписчик тоже узнаёт — один раз")
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["Привет мир"], "Сказанное до предела не теряется")
    }

    func testFailureMessageWinsOverTheHourLimitExplanation() async throws {
        // Предел достигнут, а распознавание упало. У сессии одна причина
        // конца: рассказ о сбое важнее объяснения предела и не имеет права
        // быть затёртым.
        await inserter.setInsertError(.accessibilityPermissionDenied)
        let clock = TestClock()
        let controller = makeController(clock: clock)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        clock.advance(by: DictationDurationPolicy.maximum + 1)
        controller.checkDurationLimit()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        await settle(3)

        let presented = await overlay.notices
        XCTAssertEqual(presented.count, 1, "Одна причина конца — одно сообщение")
        XCTAssertEqual(presented.first?.kind, .warning)
        XCTAssertEqual(controller.pendingRecovery?.text, "Привет мир")
    }

    func testDurationCheckDoesNotCutOffAFreshRecording() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.checkDurationLimit()
        await settle(3)

        XCTAssertEqual(controller.state, .listening, "Часовой предел не должен срабатывать сразу")
    }
}
