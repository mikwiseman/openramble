import AppKit
import Carbon.HIToolbox
import DictationCore
import XCTest

final class TextInserterTests: XCTestCase {
    private var log: CallLog!
    private var system: FakeInputSystem!
    private var pasteboard: FakePasteboard!
    private var inserter: TextInserter!

    private let target = TargetApplication(
        bundleIdentifier: "com.apple.TextEdit",
        processIdentifier: 4242,
        localizedName: "TextEdit"
    )

    override func setUp() {
        log = CallLog()
        system = FakeInputSystem(log: log)
        pasteboard = FakePasteboard(log: log)
        inserter = TextInserter(system: system, pasteboard: pasteboard)
        system.setFrontmost(target)
    }

    // MARK: - Отказы до записи в буфер

    /// Защищённый ввод: поле пароля, терминал с защитой клавиатуры.
    ///
    /// Не сбой, а нормальная ситуация — и буфер при этом трогать нельзя.
    func testПриЗащищённомВводеНичегоНеПроисходит() async {
        system.setSecureInput(true)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("привет", into: target),
            expected: TextInsertionError.secureInputActive
        )
        XCTAssertEqual(pasteboard.writtenTexts, [])
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testБезУниверсальногоДоступаНичегоНеПроисходит() async {
        system.setTrusted(false)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("привет", into: target),
            expected: TextInsertionError.accessibilityPermissionDenied
        )
        XCTAssertEqual(pasteboard.writtenTexts, [])
    }

    /// Приложение-получатель закрыли, пока шло распознавание.
    ///
    /// Вставлять «куда-нибудь» нельзя: впереди сейчас произвольное окно, вплоть
    /// до чужого поля пароля. Буфер при этом обязан остаться нетронутым — иначе
    /// человек теряет скопированное там, где вставка всё равно не состоялась.
    func testИсчезнувшаяЦельОстанавливаетВставкуИНеТрогаетБуфер() async {
        system.setActivateResult(false)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("привет", into: target),
            expected: TextInsertionError.targetUnavailable
        )
        XCTAssertEqual(pasteboard.writtenTexts, [])
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testПустойТекстНеТрогаетНиБуферНиКлавиатуру() async throws {
        try await inserter.insert("", into: target)

        XCTAssertEqual(pasteboard.writtenTexts, [])
        XCTAssertEqual(system.postedKeys.count, 0)
        XCTAssertEqual(log.entries, [])
    }

    // MARK: - Порядок

    func testФокусВозвращаетсяДоЗаписиВБуфер() async throws {
        try await inserter.insert("привет", into: target)

        XCTAssertEqual(log.entries, ["activate", "pasteboard", "post", "restore"])
    }

    func testБезЦелиВставкаЗапрещена() async {
        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("привет", into: nil),
            expected: TextInsertionError.targetUnavailable
        )
        XCTAssertEqual(log.entries, [])
    }

    // MARK: - Ожидание модификаторов

    /// Fn обязан быть в маске ожидания.
    ///
    /// Это горячая клавиша, доступная в настройках. Без `.maskSecondaryFn`
    /// ожидание заканчивалось бы, пока клавишу ещё держат, и ⌘V уходил бы в
    /// приложение как Fn+⌘V — то есть совсем другим сочетанием.
    func testЖдётОтпусканияFn() async {
        system.setHeldPlan([.maskSecondaryFn])

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("привет", into: target),
            expected: TextInsertionError.modifiersStillHeld
        )
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testЖдётОтпусканияCommand() async {
        system.setHeldPlan([.maskCommand])

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("привет", into: target),
            expected: TextInsertionError.modifiersStillHeld
        )
    }

    func testВставляетКакТолькоМодификаторыОтпущены() async throws {
        // Держат, держат, отпустили.
        system.setHeldPlan([.maskSecondaryFn, .maskSecondaryFn, .maskSecondaryFn, []])

        try await inserter.insert("привет", into: target)

        XCTAssertEqual(system.heldModifiersCallCount, 4)
        XCTAssertEqual(system.postedKeys.count, 1)
    }

    func testВМаскеОжиданияВсеМодификаторы() {
        // Отдельная прямая проверка: список легко «почистить», не заметив, что
        // именно эта клавиша и назначена горячей.
        for flag in [
            CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
        ] {
            XCTAssertTrue(
                TextInserter.watchedModifiers.contains(flag),
                "в маске ожидания нет \(flag)"
            )
        }
    }

    // MARK: - Нажатия

    func testВставкаЭтоCommandV() async throws {
        try await inserter.insert("привет", into: target)

        XCTAssertEqual(pasteboard.writtenTexts, ["привет"])
        XCTAssertEqual(system.postedKeys.count, 1)
        XCTAssertEqual(system.postedKeys.first?.keyCode, CGKeyCode(kVK_ANSI_V))
        XCTAssertEqual(system.postedKeys.first?.flags, .maskCommand)
    }

    func testНеудачнаяЗаписьВБуферОстанавливаетВставку() async {
        pasteboard.setError(.clipboardWriteFailed)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("привет", into: target),
            expected: TextInsertionError.clipboardWriteFailed
        )
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testСменаЦелиПослеЗаписиВБуферОтменяетPasteИВосстанавливаетSnapshot() async {
        let other = TargetApplication(
            bundleIdentifier: "com.apple.Terminal",
            processIdentifier: 999,
            localizedName: "Terminal"
        )
        pasteboard.onBegin = { [system] in system?.setFrontmost(other) }

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("привет", into: target),
            expected: TextInsertionError.targetChanged
        )

        XCTAssertEqual(system.postedKeys.count, 0)
        XCTAssertEqual(log.entries, ["activate", "pasteboard", "restore"])
    }

    func testОшибкаRestoreПослеPasteОтличаетсяОтНеудачнойВставки() async {
        pasteboard.setRestoreError(.clipboardWriteFailed)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("привет", into: target),
            expected: TextInsertionError.insertedButClipboardRestoreFailed
        )

        XCTAssertEqual(system.postedKeys.count, 1, "Paste уже был отправлен")
    }

    func testОтменаПослеPasteВсёРавноВосстанавливаетSnapshot() async {
        let inserter = try! XCTUnwrap(inserter)
        let system = try! XCTUnwrap(system)
        let log = try! XCTUnwrap(log)
        let target = target
        let task = Task {
            try await inserter.insert("привет", into: target)
        }
        for _ in 0..<100 where system.postedKeys.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(system.postedKeys.count, 1, "тест обязан отменить уже после Cmd+V")

        task.cancel()
        await XCTAssertThrowsErrorAsync(
            try await task.value,
            expected: TextInsertionError.insertedButClipboardRestoreFailed
        )

        XCTAssertEqual(log.entries, ["activate", "pasteboard", "post", "restore"])
    }

    func testReturnЭтоОтдельноеНажатиеБезМодификаторов() async throws {
        try await inserter.pressReturn()

        XCTAssertEqual(system.postedKeys.count, 1)
        XCTAssertEqual(system.postedKeys.first?.keyCode, CGKeyCode(kVK_Return))
        XCTAssertEqual(system.postedKeys.first?.flags, [])
    }

    func testReturnНеЖмётсяВЗащищённыйВвод() async {
        system.setSecureInput(true)

        await XCTAssertThrowsErrorAsync(
            try await inserter.pressReturn(),
            expected: TextInsertionError.secureInputActive
        )
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testReturnНеЖмётсяБезДоступа() async {
        system.setTrusted(false)

        await XCTAssertThrowsErrorAsync(
            try await inserter.pressReturn(),
            expected: TextInsertionError.accessibilityPermissionDenied
        )
    }
}

/// Асинхронный аналог `XCTAssertThrowsError` с проверкой конкретной ошибки.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: TextInsertionError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("ожидалась ошибка \(expected), но её не было", file: file, line: line)
    } catch let error as TextInsertionError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("ожидалась \(expected), пришла \(error)", file: file, line: line)
    }
}
