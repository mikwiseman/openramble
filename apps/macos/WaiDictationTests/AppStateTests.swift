import DictationCore
import LocalASR
import XCTest

/// Проводка приложения: что происходит на краях, где всё обычно и ломается.
@MainActor
final class AppStateTests: XCTestCase {
    private var harness: AppHarness!

    private var root: URL { harness.root }
    private var defaults: UserDefaults { harness.defaults }
    private var permissions: FakePermissions { harness.permissions }
    private var monitor: FakeHotkeyMonitor { harness.monitor }
    private var overlay: FakeOverlay { harness.overlay }
    private var capture: FakeCapture { harness.capture }

    override func setUpWithError() throws {
        harness = try AppHarness()
    }

    override func tearDownWithError() throws {
        harness.tearDown()
    }

    private func makeState() -> AppState { harness.makeState() }

    private func installModelMarker() throws { try harness.installModelMarker() }

    // MARK: - Разрешения

    func testБезУниверсальногоДоступаСлежениеНеИдёт() {
        permissions.accessibilityGranted = false

        let state = makeState()

        XCTAssertFalse(state.accessibilityGranted)
        XCTAssertFalse(state.isDictationReady)
        XCTAssertFalse(monitor.isRunning)
    }

    func testСДоступомСлежениеЗапускается() {
        permissions.accessibilityGranted = true

        _ = makeState()

        XCTAssertTrue(monitor.isRunning)
    }

    /// Доступ отобрали, пока приложение работало.
    ///
    /// Слежение обязано остановиться: система всё равно перестала отдавать
    /// события, а живая подписка создавала бы вид, что клавиша работает.
    func testОтозванныйДоступОстанавливаетСлежение() {
        permissions.accessibilityGranted = true
        let state = makeState()
        XCTAssertTrue(monitor.isRunning)

        permissions.accessibilityGranted = false
        state.refreshPermissions()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(state.isDictationReady)
    }

    func testБезМикрофонаДиктовкаНеГотова() {
        permissions.microphoneGranted = false

        let state = makeState()

        XCTAssertFalse(state.isDictationReady)
    }

    /// Нажатие клавиши без разрешений не должно запускать запись.
    func testБезРазрешенийНажатиеНичегоНеЗапускает() {
        permissions.accessibilityGranted = false
        permissions.microphoneGranted = false
        let state = makeState()

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: - Модель

    func testБезМоделиНажатиеНичегоНеЗапускает() async {
        let state = makeState()
        await state.refreshModelState()
        XCTAssertFalse(state.modelState.isReady)

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
    }

    func testСМодельюИРазрешениямиНажатиеЗапускаетДиктовку() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        XCTAssertTrue(state.modelState.isReady)

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .preparing)
    }

    /// Удаление модели посреди диктовки.
    ///
    /// Модель сейчас в работе. Снести её из-под себя значит потерять уже
    /// сказанное и показать вместо этого невнятную ошибку загрузки.
    func testМодельНеУдаляетсяВоВремяДиктовки() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        XCTAssertNotEqual(state.dictationState, .idle)

        state.deleteModel()

        XCTAssertEqual(state.lastNotice?.kind, .warning)
        XCTAssertEqual(state.modelState.isReady, true)
        // Сообщение обязано дойти до экрана, а не осесть в поле. Показывается
        // оно задачей, поэтому даём ей дойти до оверлея.
        try await Task.sleep(for: .milliseconds(100))
        let notices = await overlay.notices
        XCTAssertTrue(notices.contains { $0.message.contains("Дождитесь") })
    }

    func testВПокоеМодельУдаляется() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        XCTAssertTrue(state.modelState.isReady)

        state.deleteModel()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(state.modelState.isReady)
    }

    // MARK: - Жесты

    func testДвойноеНажатиеВПокоеНачинаетДиктовкуБезУдержания() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        monitor.onDoubleTap?()

        XCTAssertEqual(state.dictationState, .preparing)
        XCTAssertTrue(state.isHandsFreeActive)
    }

    /// Двойное нажатие приходит уже после того, как первое запустило сессию.
    ///
    /// Начать новую в этот момент нельзя — она не прошла бы проверку на
    /// свободное состояние, и режим без удержания остался бы недостижим.
    func testДвойноеНажатиеПоверхИдущейСессииПереводитЕёВРежимБезУдержания() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        XCTAssertFalse(state.isHandsFreeActive)

        monitor.onDoubleTap?()

        XCTAssertTrue(state.isHandsFreeActive)
        XCTAssertTrue(monitor.isHandsFreeActive, "монитору нужно знать режим, иначе следующее нажатие начнёт новую диктовку вместо остановки")
    }

    func testEscapeВПокоеНичегоНеОтменяет() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        // Пока диктовки нет, Escape — обычная клавиша чужого приложения.
        monitor.onEscape?()

        XCTAssertEqual(state.dictationState, .idle)
        let aborts = await capture.abortCount
        XCTAssertEqual(aborts, 0)
    }

    func testEscapeВоВремяДиктовкиОтменяетЕё() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()

        monitor.onEscape?()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: - Настройки

    func testСменаКлавишиДоходитДоМонитораИСохраняется() {
        let state = makeState()

        state.hotkey = .leftControl

        XCTAssertEqual(monitor.hotkey, .leftControl)
        XCTAssertEqual(defaults.string(forKey: "hotkey"), "leftControl")
        XCTAssertEqual(makeState().hotkey, .leftControl)
    }

    func testПредупреждениеПоказываетсяТолькоДляFn() {
        defaults.set(1, forKey: "AppleFnUsageType")
        let state = makeState()

        XCTAssertNil(state.hotkeyWarning)

        state.hotkey = .fn

        XCTAssertNotNil(state.hotkeyWarning)
    }

    // MARK: - Словарь

    func testСловарьСохраняетсяИПереживаетПерезапуск() {
        let state = makeState()

        state.addReplacement(spoken: "сентри", written: "Sentry")

        XCTAssertEqual(state.replacements.map(\.written), ["Sentry"])
        XCTAssertEqual(makeState().replacements.map(\.written), ["Sentry"])
    }

    func testПустыеПоляНеДобавляются() {
        let state = makeState()

        state.addReplacement(spoken: "   ", written: "Sentry")
        state.addReplacement(spoken: "сентри", written: " ")

        XCTAssertEqual(state.replacements, [])
    }

    /// Непрочитанный словарь блокирует запись целиком.
    ///
    /// Раньше он превращался в пустой массив, и первая же правка перезаписывала
    /// им ключ: человек терял всё накопленное молча и необратимо.
    func testНепрочитанныйСловарьНеПерезаписывается() async {
        let broken = "{это не json"
        defaults.set(Data(broken.utf8), forKey: "replacements")

        let state = makeState()
        XCTAssertFalse(state.isDictionaryEditable)
        XCTAssertNotNil(state.dictionaryProblem)

        state.addReplacement(spoken: "сентри", written: "Sentry")

        XCTAssertEqual(state.replacements, [])
        XCTAssertEqual(
            defaults.data(forKey: "replacements").map { String(decoding: $0, as: UTF8.self) },
            broken,
            "исходные данные обязаны остаться на месте"
        )
    }

    func testПроНепрочитанныйСловарьГоворятСразу() async {
        defaults.set(Data("{это не json".utf8), forKey: "replacements")

        _ = makeState()
        // Сообщение показывается задачей, поэтому даём ей дойти до оверлея.
        try? await Task.sleep(for: .milliseconds(100))

        let notices = await overlay.notices
        XCTAssertTrue(notices.contains { $0.message.contains("Словарь") })
    }

    func testСловарьИзБудущегоНеТрогается() {
        let future = #"{"version": 99, "items": []}"#
        defaults.set(Data(future.utf8), forKey: "replacements")

        let state = makeState()
        state.addStarterDictionary()

        XCTAssertFalse(state.isDictionaryEditable)
        XCTAssertEqual(
            defaults.data(forKey: "replacements").map { String(decoding: $0, as: UTF8.self) },
            future
        )
    }

    func testУдалениеЗаменыСохраняется() {
        let state = makeState()
        state.addReplacement(spoken: "сентри", written: "Sentry")
        state.addReplacement(spoken: "деплой", written: "deploy")

        state.removeReplacements(at: IndexSet(integer: 0))

        XCTAssertEqual(state.replacements.map(\.written), ["deploy"])
        XCTAssertEqual(makeState().replacements.map(\.written), ["deploy"])
    }

    func testНаборТерминовДобавляетсяОдинРаз() {
        let state = makeState()
        let available = state.availableStarterCount
        XCTAssertGreaterThan(available, 0)

        state.addStarterDictionary()

        XCTAssertEqual(state.replacements.count, available)
        XCTAssertEqual(state.availableStarterCount, 0)
    }

    // MARK: - Уборка

    /// Записи, уцелевшие после падения приложения, убираются при запуске.
    func testЗапускПодметаетБрошенныеЗаписи() throws {
        let paths = AppPaths(root: root)
        let orphan = try paths.takes().appending(path: "take-старая.wav")
        try Data("звук".utf8).write(to: orphan)

        _ = makeState()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}
