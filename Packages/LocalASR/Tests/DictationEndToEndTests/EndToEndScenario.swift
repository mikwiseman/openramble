import DictationCore
import Foundation
import LocalASR
import XCTest

/// Фразы, которые «наговариваются» в сквозных тестах.
///
/// Английские термины записаны латиницей — так же, как их произносит человек и
/// как их читает системный голос. Именно это и есть главный сценарий продукта:
/// внутри русской фразы модель честно пишет термин кириллицей, а обратно его
/// возвращает словарь замен.
enum Phrase {
    /// Главный сценарий: русская речь с английскими терминами.
    static let mixed = "Я открыл pull request в GitHub, прогнал linter и запустил deploy на production."
    static let mixedTerms = ["pull request", "GitHub", "linter", "deploy", "production"]

    /// Команда «отправь» в конце фразы.
    static let send = "Проверь мой pull request, пожалуйста, отправь"
    /// Команда «новая строка» в конце фразы.
    static let newLine = "Первая мысль, новая строка"

    /// Совсем другая тема: по ней видно, если две диктовки смешались.
    static let other = "Совершенно другая тема: завтра я лечу в Берлин на конференцию."
    /// Слово, которого нет ни в одной другой фразе.
    static let otherMarker = "Берлин"

    /// Короткая фраза примерно на четыре секунды.
    static let short = "Сегодня я хочу коротко рассказать, как устроен наш рабочий день."

    /// Термины в косвенных падежах — так их и произносят по-русски.
    /// Термины в косвенных падежах.
    ///
    /// «Питона» здесь больше нет намеренно. Замер на свежих записях показал, что
    /// эта запись не срабатывала ни разу — модель пишет на месте Python слово
    /// «написан», — зато превращала «питон сжал добычу» в «Python сжал добычу».
    /// Ради термина, который всё равно не ловится, ломать русский язык нельзя.
    static let declined = "Я пишу на свифте, проверяю в билде, без даунтайма."
    static let declinedTerms = ["Swift", "build", "downtime"]

    /// Слово, похожее на термин, но не термин.
    static let falseFriend = "Я живу в центре города, недалеко от парка."

    /// Английская речь с английской же командой в конце.
    static let englishSend = "Please review my pull request send it"

    /// Абзац примерно на тридцать шесть секунд.
    static let long = """
        Сегодня я хочу коротко рассказать, как устроен наш рабочий день и почему мы поменяли \
        порядок выкладки. Утром мы смотрим, что накопилось за ночь, разбираем ошибки и решаем, \
        что берём в работу. Днём мы пишем код, обсуждаем решения и правим то, что нашли вчера. \
        Вечером мы собираем сборку, прогоняем тесты и смотрим на графики. Раньше выкладка \
        занимала почти час, и половину этого времени мы просто ждали. Теперь она занимает семь \
        минут, и мы можем выкладывать несколько раз в день. Главное изменение простое: мы \
        перестали делать всё руками и описали каждый шаг заранее.
        """
    /// Слово, которого нет в остальных фразах, — метка длинной записи.
    static let longMarker = "выкладк"

    /// Тот же абзац пять раз — примерно три минуты.
    static var veryLong: String {
        Array(repeating: long, count: 5).joined(separator: "\n\n")
    }
}

/// Общая обвязка сквозного теста.
///
/// Собирает продукт целиком: контроллер диктовки из DictationCore, настоящий
/// `LocalTranscriber` с загруженной моделью Parakeet и настоящий `TextPipeline`
/// со стартовым словарём. Подставлены ровно два края: микрофон и чужое
/// приложение.
@MainActor
class EndToEndScenario: XCTestCase {
    private(set) var transcriber: LocalTranscriber!
    private(set) var capture: FixturePlaybackCapture!
    private(set) var inserter: RecordingInserter!
    private(set) var overlay: RecordingOverlay!
    private(set) var sounds: CountingSounds!
    private(set) var probe: TranscriptionProbe!
    private(set) var workspace: URL!

    override func setUp() async throws {
        try await super.setUp()

        // Модель — первым делом: без неё тест не проваливается, а пропускается.
        transcriber = try await requireEndToEndTranscriber()

        workspace = FileManager.default.temporaryDirectory
            .appending(path: "e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        capture = FixturePlaybackCapture(
            directory: workspace.appending(path: "records", directoryHint: .isDirectory)
        )
        inserter = RecordingInserter()
        overlay = RecordingOverlay()
        sounds = CountingSounds()
        probe = TranscriptionProbe()
    }

    override func tearDown() async throws {
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        try await super.tearDown()
    }

    // MARK: - Сборка цепочки

    /// Контроллер, у которого настоящее всё, кроме микрофона и чужого приложения.
    func makeController(
        replacements: [DictionaryReplacement] = StarterDictionary.developer
    ) -> DictationController {
        let engine = transcriber!
        let watcher = probe!

        return DictationController(
            capture: capture,
            transcribe: { url in
                await watcher.willStart(url)
                do {
                    let result = try await engine.transcribe(fileURL: url)
                    await watcher.didFinish(result)
                    return result
                } catch {
                    await watcher.didFail(error)
                    throw error
                }
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { TextPipeline(replacements: replacements) }
        )
    }

    // MARK: - Звук

    /// Синтезировать фразу и поставить её в очередь захвата.
    func speak(_ text: String, voice: SpeechVoice = .russian) async throws {
        let file = try await fixture { try await SpeechFixtures.shared.speech(text, voice: voice) }
        await capture.enqueue([file])
    }

    /// Поставить в очередь запись, где человек молчит.
    func stayQuiet(seconds: Double) async throws {
        let file = try await fixture { try await SpeechFixtures.shared.silence(seconds: seconds) }
        await capture.enqueue([file])
    }

    /// Поставить в очередь обрывок настоящей речи — «нажал и сразу отпустил».
    func speakBriefly(_ text: String, seconds: Double) async throws {
        let file = try await fixture {
            let full = try await SpeechFixtures.shared.speech(text)
            return try await SpeechFixtures.shared.truncated(full, toSeconds: seconds)
        }
        await capture.enqueue([file])
    }

    /// Синтез недоступен — тест пропускается с объяснением, а не падает.
    private func fixture(_ make: () async throws -> URL) async throws -> URL {
        do {
            return try await make()
        } catch let failure as FixtureFailure {
            throw XCTSkip("Сквозной тест пропущен — \(failure.description)")
        }
    }

    // MARK: - Ожидания

    /// Подождать, пока условие станет истинным.
    ///
    /// Опрос, а не фиксированная пауза: путь через настоящую модель занимает то
    /// столько, то столько, и «поспать двести миллисекунд» здесь означало бы
    /// либо мигающий тест, либо лишние секунды в каждом прогоне.
    func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(60),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Не дождались: \(what)", file: file, line: line)
    }

    /// Провести одну диктовку целиком: нажал, поговорил, отпустил.
    func dictate(
        with controller: DictationController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitUntil("запись пошла", file: file, line: line) { controller.state == .listening }
        controller.stop()
        await waitUntil("сессия закрылась", file: file, line: line) { controller.state == .idle }
    }

    // MARK: - Проверки

    /// Убедиться, что после сессии на диске не осталось голоса пользователя.
    ///
    /// С ожиданием, а не мгновенно, и это находка сквозного прогона: удаление
    /// записи стоит в `defer` завершающей задачи, а состояние «свободно»
    /// выставляется раньше неё. На пути отмены — вообще из другой задачи, и
    /// зазор растягивается на всё время работы движка. Возвращённая задержка
    /// печатается в тесте отмены: это и есть измеренный размер зазора.
    @discardableResult
    func assertNoRecordingsLeft(
        timeout: Duration = .seconds(15),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Duration {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await capture.leftoverTakes.isEmpty { return started.duration(to: .now) }
            try? await Task.sleep(for: .milliseconds(2))
        }

        let leftovers = await capture.leftoverTakes
        XCTFail(
            "Запись осталась на диске: \(leftovers.map(\.lastPathComponent))",
            file: file,
            line: line
        )
        return started.duration(to: .now)
    }

    /// Длительность в миллисекундах — для печати в диагностике.
    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Убедиться, что пользователю не показали ни одной жалобы.
    func assertNoFailureNotices(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let notices = await overlay.notices
        XCTAssertEqual(
            notices.filter { $0.kind != .info }.map(\.message),
            [],
            "Сценарий обязан пройти без предупреждений",
            file: file,
            line: line
        )
    }
}

// MARK: - Разбор текста

extension String {
    /// Позиции вхождений — по ним видно, сохранился ли порядок слов.
    func position(of needle: String) -> Int? {
        range(of: needle, options: [.caseInsensitive]).map {
            distance(from: startIndex, to: $0.lowerBound)
        }
    }

    func containsInsensitive(_ needle: String) -> Bool {
        range(of: needle, options: [.caseInsensitive]) != nil
    }

    /// Сколько раз встретилось — по этому видно, дошла ли длинная запись целиком.
    func occurrences(of needle: String) -> Int {
        var count = 0
        var cursor = startIndex
        while let found = range(of: needle, options: [.caseInsensitive], range: cursor..<endIndex) {
            count += 1
            cursor = found.upperBound
        }
        return count
    }

    var wordCount: Int {
        split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
