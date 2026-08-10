import DictationCore
import XCTest

/// Storing a dictionary of replacements.
///
/// The dictionary is the only thing that a person types in this application with his hands.
/// Each test here is about one thing: unread should not turn into empty and
/// overwrite the accumulated.
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

    // MARK: - Ordinary life

    func testScenario001() {
        let loaded = store.load()

        XCTAssertEqual(loaded.replacements, [])
        XCTAssertNil(loaded.problem)
    }

    func testScenario002() throws {
        let items = [
            DictionaryReplacement(spoken: "Sentry", written: "Sentry"),
            DictionaryReplacement(spoken: "pull request", written: "pull request"),
        ]

        try store.save(items)

        XCTAssertEqual(store.load().replacements, items)
        XCTAssertNil(store.load().problem)
    }

    func testScenario003() throws {
        try store.save([DictionaryReplacement(spoken: "code", written: "code")])

        let json = try XCTUnwrap(storedJSON)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNotNil(object["items"])
    }

    func testScenario004() throws {
        try store.save([DictionaryReplacement(spoken: "code", written: "code")])
        try store.save([])

        XCTAssertEqual(store.load().replacements, [])
        XCTAssertNil(store.load().problem)
    }

    // MARK: - Moving from the old format

    func testScenario005() throws {
        let items = [DictionaryReplacement(spoken: "deploy", written: "deploy")]
        defaults.set(try JSONEncoder().encode(items), forKey: key)

        let loaded = store.load()

        XCTAssertEqual(loaded.replacements, items)
        XCTAssertNil(loaded.problem, "the old format is not an accident, but normal data")
    }

    func testScenario006() throws {
        let items = [DictionaryReplacement(spoken: "deploy", written: "deploy")]
        defaults.set(try JSONEncoder().encode(items), forKey: key)

        try store.save(store.load().replacements)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key)))
                as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(store.load().replacements, items)
    }

    // MARK: - Unread

    /// Broken JSON.
    ///
    /// Previously, an empty array was returned here - and the first edit of the dictionary
    /// rewrote the key for them. The man lost everything he had accumulated silently and forever.
    func testScenario007() throws {
        write("{this is not json")

        let loaded = store.load()

        guard case let .unreadable(quarantineKey) = loaded.problem else {
            return XCTFail("Expected an unreadable marker, received \(String(describing: loaded.problem))")
        }
        XCTAssertEqual(loaded.replacements, [])
        // The original data is still there - quarantine did not transfer it, but copied it.
        XCTAssertEqual(storedJSON, "{this is not json")
        XCTAssertEqual(
            defaults.data(forKey: quarantineKey).map { String(decoding: $0, as: UTF8.self) },
            "{this is not json"
        )
    }

    func testScenario008() throws {
        write(#"{"version": 1, "items": [{"id": "not"#)

        guard case .unreadable = store.load().problem else {
            return XCTFail("truncated data must be considered unread")
        }
    }

    func testScenario009() {
        write(#"{"favouriteColour": "blue"}"#)

        guard case .unreadable = store.load().problem else {
            return XCTFail("an unfamiliar structure must be considered unread")
        }
    }

    func testScenario010() {
        // Empty data is not “no dictionary”, but “something went wrong”:
        // missing dictionary looks like missing key.
        defaults.set(Data(), forKey: key)

        guard case .unreadable = store.load().problem else {
            return XCTFail("empty value must be considered unread")
        }
    }

    func testScenario011() {
        write(#"{"version": 0, "items": []}"#)

        guard case .unreadable = store.load().problem else {
            return XCTFail("version zero is not our format")
        }
    }

    func testScenario012() {
        // Parsing half and writing it back means losing the other half.
        write(#"{"version": 1, "items": [{"spoken": "code"}]}"#)

        guard case .unreadable = store.load().problem else {
            return XCTFail("an incomplete element must block the entire record")
        }
    }

    // MARK: - Version from the future

    /// Rollback the application to a version back.
    ///
    /// The old application must see someone else's format and not touch it: otherwise
    /// Rolling back for a day destroys the dictionary accumulated over a month.
    func testScenario013() throws {
        let future = #"{"version": 99, "items": [{"id": "x", "spoken": "a", "written": "b"}]}"#
        write(future)

        let loaded = store.load()

        XCTAssertEqual(loaded.problem, .writtenByNewerVersion(99))
        XCTAssertEqual(loaded.replacements, [])
        XCTAssertEqual(storedJSON, future, "new version data must remain untouched")
        // Quarantine is not needed here: the data is intact, just not ours.
        XCTAssertTrue(
            defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("\(key).unreadable") }
        )
    }

    func testScenario014() throws {
        let future = #"{"version": 99, "items": []}"#
        write(future)

        // The store itself does not prohibit anything - the ban is kept by `AppState`. It's important here
        // only that reading did not replace the data with empty ones.
        XCTAssertEqual(storedJSON, future)
    }
}
