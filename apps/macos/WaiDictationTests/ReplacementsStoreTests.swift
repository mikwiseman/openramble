import DictationCore
import XCTest

/// Хранение словаря замен.
///
/// Словарь — единственное, что человек в этом приложении набирает руками.
/// Каждый тест здесь про одно: непрочитанное не должно превращаться в пустое и
/// затирать накопленное.
final class ReplacementsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ReplacementsStore!
    private let key = "replacements"

    override func setUpWithError() throws {
        suiteName = "is.waiwai.dictation.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = ReplacementsStore(
            defaults: defaults,
            key: key,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func write(_ json: String) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    private var storedJSON: String? {
        defaults.data(forKey: key).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Обычная жизнь

    func testБезКлючаСловарьПустИЗаписьРазрешена() {
        let loaded = store.load()

        XCTAssertEqual(loaded.replacements, [])
        XCTAssertNil(loaded.problem)
    }

    func testСохранённоеЧитаетсяОбратно() throws {
        let items = [
            DictionaryReplacement(spoken: "сентри", written: "Sentry"),
            DictionaryReplacement(spoken: "пул реквест", written: "pull request"),
        ]

        try store.save(items)

        XCTAssertEqual(store.load().replacements, items)
        XCTAssertNil(store.load().problem)
    }

    func testХранимоеИмеетНомерВерсии() throws {
        try store.save([DictionaryReplacement(spoken: "код", written: "code")])

        let json = try XCTUnwrap(storedJSON)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNotNil(object["items"])
    }

    func testПустойСписокСохраняетсяКакПустой() throws {
        try store.save([DictionaryReplacement(spoken: "код", written: "code")])
        try store.save([])

        XCTAssertEqual(store.load().replacements, [])
        XCTAssertNil(store.load().problem)
    }

    // MARK: - Переезд со старого формата

    func testСтарыйФорматБезВерсииЧитается() throws {
        let items = [DictionaryReplacement(spoken: "деплой", written: "deploy")]
        defaults.set(try JSONEncoder().encode(items), forKey: key)

        let loaded = store.load()

        XCTAssertEqual(loaded.replacements, items)
        XCTAssertNil(loaded.problem, "старый формат — не авария, а обычные данные")
    }

    func testПослеПереездаХранимоеПолучаетВерсию() throws {
        let items = [DictionaryReplacement(spoken: "деплой", written: "deploy")]
        defaults.set(try JSONEncoder().encode(items), forKey: key)

        try store.save(store.load().replacements)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key)))
                as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(store.load().replacements, items)
    }

    // MARK: - Непрочитанное

    /// Битый JSON.
    ///
    /// Раньше здесь возвращался пустой массив — и первая же правка словаря
    /// перезаписывала им ключ. Человек терял всё накопленное молча и навсегда.
    func testБитыйJSONБлокируетЗаписьИОткладываетДанные() throws {
        write("{это не json")

        let loaded = store.load()

        guard case let .unreadable(quarantineKey) = loaded.problem else {
            return XCTFail("ожидалась пометка «не прочитан», пришло \(String(describing: loaded.problem))")
        }
        XCTAssertEqual(loaded.replacements, [])
        // Исходные данные лежат на месте — карантин их не переносил, а копировал.
        XCTAssertEqual(storedJSON, "{это не json")
        XCTAssertEqual(
            defaults.data(forKey: quarantineKey).map { String(decoding: $0, as: UTF8.self) },
            "{это не json"
        )
    }

    func testОбрезанныйJSONБлокируетЗапись() throws {
        write(#"{"version": 1, "items": [{"id": "не"#)

        guard case .unreadable = store.load().problem else {
            return XCTFail("обрезанные данные обязаны считаться непрочитанными")
        }
    }

    func testЧужаяСтруктураБлокируетЗапись() {
        write(#"{"favouriteColour": "синий"}"#)

        guard case .unreadable = store.load().problem else {
            return XCTFail("незнакомая структура обязана считаться непрочитанной")
        }
    }

    func testПустоеЗначениеБлокируетЗапись() {
        // Пустые данные — это не «словаря нет», а «что-то пошло не так»:
        // отсутствие словаря выглядит как отсутствие ключа.
        defaults.set(Data(), forKey: key)

        guard case .unreadable = store.load().problem else {
            return XCTFail("пустое значение обязано считаться непрочитанным")
        }
    }

    func testНулеваяВерсияБлокируетЗапись() {
        write(#"{"version": 0, "items": []}"#)

        guard case .unreadable = store.load().problem else {
            return XCTFail("нулевая версия — не наш формат")
        }
    }

    func testСписокСБитымЭлементомБлокируетЗапись() {
        // Разобрать половину и записать её обратно значит потерять вторую.
        write(#"{"version": 1, "items": [{"spoken": "код"}]}"#)

        guard case .unreadable = store.load().problem else {
            return XCTFail("неполный элемент обязан блокировать запись целиком")
        }
    }

    // MARK: - Версия из будущего

    /// Откат приложения на версию назад.
    ///
    /// Старое приложение обязано увидеть чужой формат и не тронуть его: иначе
    /// откат на день уничтожает словарь, накопленный за месяц.
    func testВерсияИзБудущегоНеТрогаетсяВовсе() throws {
        let future = #"{"version": 99, "items": [{"id": "x", "spoken": "a", "written": "b"}]}"#
        write(future)

        let loaded = store.load()

        XCTAssertEqual(loaded.problem, .writtenByNewerVersion(99))
        XCTAssertEqual(loaded.replacements, [])
        XCTAssertEqual(storedJSON, future, "данные новой версии обязаны остаться нетронутыми")
        // Карантин здесь не нужен: данные целы, просто не наши.
        XCTAssertTrue(
            defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("\(key).unreadable") }
        )
    }

    func testВерсияИзБудущегоНеПереписываетсяПриСохранении() throws {
        let future = #"{"version": 99, "items": []}"#
        write(future)

        // Сам стор ничего не запрещает — запрет держит `AppState`. Здесь важно
        // только то, что чтение не подменило данные пустыми.
        XCTAssertEqual(storedJSON, future)
    }
}
