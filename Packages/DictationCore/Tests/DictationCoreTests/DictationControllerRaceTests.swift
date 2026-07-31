import XCTest
@testable import DictationCore

// MARK: - Края, которыми можно управлять по тактам

/// Ворота: держат вызов, пока тест их не откроет.
///
/// Отмена в Swift не прерывает уже начатое ожидание — она только помечает его.
/// Ворота воспроизводят это честно: продолжение просыпается тогда, когда решит
/// тест, а не тогда, когда сработала отмена. Именно в этот зазор и попадают
/// хвосты отменённых сессий.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Микрофон, у которого видно, включён ли он прямо сейчас.
///
/// Ведёт себя как настоящий движок: вторую запись поверх идущей не начинает, а
/// отказывает. Без этого тест не отличил бы «микрофон погашен» от «микрофон
/// забыт включённым», а это и есть главное обещание продукта.
actor TrackedCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var isRecording = false
    private(set) var inFlight = 0

    private var startGate: Gate?
    private let file = URL(fileURLWithPath: "/tmp/tracked-take.wav")

    func setStartGate(_ gate: Gate?) { startGate = gate }

    func startRecording() async throws -> URL {
        startCount += 1
        inFlight += 1
        defer { inFlight -= 1 }
        if let startGate { await startGate.pass() }
        guard !isRecording else { throw AudioCaptureError.engineUnavailable("запись уже идёт") }
        isRecording = true
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        inFlight += 1
        defer { inFlight -= 1 }
        guard isRecording else { throw AudioCaptureError.notRecording }
        isRecording = false
        return (file, 2.0)
    }

    func abortRecording() async { isRecording = false }
}

actor RecordingInserter: TextInserting {
    private(set) var insertedTexts: [String] = []

    func insert(_ text: String, into target: TargetApplication?) async throws {
        insertedTexts.append(text)
    }
    func pressReturn() async throws {}
    nonisolated func frontmostApplication() -> TargetApplication? { nil }
}

actor QuietOverlay: OverlayPresenting {
    func present(_ state: DictationState, elapsed: TimeInterval) async {}
    func dismiss() async {}
    func presentNotice(_ notice: DictationNotice) async {}
}

actor CountingSounds: Sounding {
    private(set) var startPlays = 0
    func playStart() async { startPlays += 1 }
    func playStop() async {}
}

actor NoopRecovery: RecoveryStoring {
    func save(_ text: String) async throws -> URL { URL(fileURLWithPath: "/tmp/noop.txt") }
}

/// Счётчик обращений к распознаванию, доступный из `@Sendable`-замыкания.
actor TranscribeTracker {
    private(set) var inFlight = 0
    private(set) var count = 0
    func enter() { count += 1; inFlight += 1 }
    func leave() { inFlight -= 1 }
}

/// Воспроизводимый генератор: упавший прогон должен повторяться по номеру.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Тесты гонок

/// Гонки между жестами пользователя и хвостами уже отменённых сессий.
///
/// Всё, что здесь проверяется, невозможно поймать чтением: отмена помечает
/// ожидание, но не прерывает его, и продолжение просыпается уже в чужой сессии.
@MainActor
final class DictationControllerRaceTests: XCTestCase {
    private var capture: TrackedCapture!
    private var inserter: RecordingInserter!
    private var overlay: QuietOverlay!
    private var sounds: CountingSounds!
    private var transcribes: TranscribeTracker!

    override func setUp() async throws {
        capture = TrackedCapture()
        inserter = RecordingInserter()
        overlay = QuietOverlay()
        sounds = CountingSounds()
        transcribes = TranscribeTracker()
    }

    private func makeController(
        recognized: String = "привет мир",
        transcribeGate: Gate? = nil
    ) -> DictationController {
        let tracker = transcribes!
        return DictationController(
            capture: capture,
            transcribe: { _ in
                await tracker.enter()
                defer { Task { await tracker.leave() } }
                if let transcribeGate { await transcribeGate.pass() }
                return ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            recovery: NoopRecovery()
        )
    }

    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Дождаться, пока улягутся все хвосты: и состояние, и края системы.
    private func quiesce(_ controller: DictationController, limit: Int = 400) async {
        for _ in 0..<limit {
            let captureIdle = await capture.inFlight == 0
            let transcribeIdle = await transcribes.inFlight == 0
            if controller.state == .idle, captureIdle, transcribeIdle { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        await settle(4)
    }

    // MARK: - Хвост отменённой сессии

    func testStaleFinalizationDoesNotTearDownTheNextSession() async throws {
        // Распознавание висит в воротах. Отмена его помечает, но не будит —
        // ровно как настоящее распознавание, которое дочитывает свой буфер.
        let gate = Gate()
        let controller = makeController(transcribeGate: gate)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        await settle()
        XCTAssertEqual(controller.state, .idle, "Отмена обязана закрыть сессию сразу")

        // Человек не ждёт: сразу диктует заново.
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        // Теперь просыпается хвост отменённой сессии.
        await gate.open()
        await settle(20)

        XCTAssertEqual(
            controller.state,
            .listening,
            "Хвост отменённой сессии не должен гасить новую"
        )
        let stillRecording = await capture.isRecording
        XCTAssertTrue(stillRecording, "Микрофон новой сессии обязан остаться включённым")

        // И новая сессия обязана нормально дойти до вставки.
        controller.stop()
        await quiesce(controller)
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["Привет мир"], "Вторая диктовка не должна пропасть")
    }

    func testStaleStartDoesNotAdoptTheNextSession() async throws {
        // Запись поднимается медленно: отпустить и отменить успевают раньше.
        let gate = Gate()
        await capture.setStartGate(gate)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(3)
        controller.cancel()
        await settle(3)
        XCTAssertEqual(controller.state, .idle)

        // Вторая сессия начинается, пока первая ещё висит в запуске движка.
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(3)

        await gate.open()
        await quiesce(controller)

        let plays = await sounds.startPlays
        XCTAssertLessThanOrEqual(plays, 1, "Один живой сеанс — один звук начала записи")

        // Главное: после того как всё улеглось, микрофон обязан быть погашен.
        controller.cancel()
        await quiesce(controller)
        let recording = await capture.isRecording
        XCTAssertFalse(recording, "Микрофон не должен остаться включённым от брошенного запуска")
    }

    // MARK: - Шторм жестов

    func testRandomGestureStormsAlwaysLeaveTheMicrophoneOff() async throws {
        // Сотни случайных чередований. Проверяется не «правильный» исход
        // каждого — их слишком много, — а два обещания, которые обязаны
        // держаться всегда: микрофон погашен и следующая диктовка работает.
        for seed in 0..<200 {
            capture = TrackedCapture()
            inserter = RecordingInserter()
            overlay = QuietOverlay()
            sounds = CountingSounds()
            transcribes = TranscribeTracker()

            let controller = makeController()
            var rng = SeededGenerator(seed: UInt64(seed))

            for _ in 0..<6 {
                switch Int(rng.next() % 7) {
                case 0: controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
                case 1: controller.begin(handsFree: true, isEnabled: true, isModelReady: true)
                case 2: controller.stop()
                case 3: controller.cancel()
                case 4: controller.interrupt(reason: "диск заполнен")
                case 5: controller.promoteToHandsFree()
                default: controller.stopHandsFree()
                }
                let pause = Int(rng.next() % 4)
                if pause > 0 { try? await Task.sleep(for: .milliseconds(pause)) }
                else { await Task.yield() }
            }

            // Клавишу в конце шторма отпускают всегда: рука не остаётся на кнопке.
            controller.stop()
            controller.stopHandsFree()
            await quiesce(controller)

            XCTAssertEqual(controller.state, .idle, "Сессия зависла, seed \(seed)")
            let recording = await capture.isRecording
            XCTAssertFalse(recording, "Микрофон остался включённым, seed \(seed)")

            let insertedBefore = await inserter.insertedTexts.count
            let startsBefore = await capture.startCount
            XCTAssertLessThanOrEqual(
                insertedBefore,
                startsBefore,
                "Вставок больше, чем записей — текст задвоился, seed \(seed)"
            )

            // Из любого исхода шторма должен быть выход: обычная диктовка работает.
            controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
            await settle(6)
            controller.stop()
            await quiesce(controller)

            let insertedAfter = await inserter.insertedTexts.count
            XCTAssertEqual(
                insertedAfter,
                insertedBefore + 1,
                "После шторма диктовка обязана снова работать, seed \(seed)"
            )
        }
    }
}
