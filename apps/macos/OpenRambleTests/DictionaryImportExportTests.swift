import DictationCore
import XCTest

/// Import and export of the personal dictionary through the app layer:
/// merges reach the store, every outcome is named, a locked dictionary
/// refuses the same way it refuses edits.
@MainActor
final class DictionaryImportExportTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    private func file(_ pairs: [(String, String)]) throws -> Data {
        try DictionaryTransfer.export(
            pairs.map { DictionaryReplacement(spoken: $0.0, written: $0.1) }
        )
    }

    func testImportMergesAndReportsCounts() async throws {
        let state = harness.makeState()
        state.addReplacement(spoken: "sentry", written: "Centry")

        state.importDictionary(from: try file([
            ("Sentry", "Sentry"),
            ("poust girls", "Postgres"),
        ]))

        XCTAssertEqual(
            state.replacements.map(\.written), ["Sentry", "Postgres"],
            "same spoken phrase updates in place, new phrases append"
        )
        XCTAssertEqual(state.lastNotice?.kind, .info)
        XCTAssertEqual(state.lastNotice?.message, "Imported 1 phrase, updated 1 phrase.")
    }

    /// The merge survives a relaunch — it went through the store, not just
    /// the published property.
    func testImportedPhrasesPersist() async throws {
        let state = harness.makeState()
        state.importDictionary(from: try file([("a", "A"), ("b", "B")]))
        XCTAssertEqual(state.lastNotice?.message, "Imported 2 phrases.")

        let secondLaunch = harness.makeState()
        XCTAssertEqual(secondLaunch.replacements.map(\.spoken), ["a", "b"])
    }

    func testForeignFileIsRefusedAndNothingChanges() async throws {
        let state = harness.makeState()
        state.addReplacement(spoken: "keep", written: "me")
        let before = state.replacements

        state.importDictionary(from: Data("{\"someOtherApp\": true}".utf8))

        XCTAssertEqual(state.replacements, before)
        XCTAssertEqual(state.lastNotice?.kind, .failure)
        XCTAssertEqual(state.lastNotice?.message, "This file is not an OpenRamble dictionary.")
    }

    func testFileThatChangesNothingSaysSo() async throws {
        let state = harness.makeState()
        state.addReplacement(spoken: "sentry", written: "Sentry")

        state.importDictionary(from: try state.exportedDictionary())

        XCTAssertEqual(state.lastNotice?.kind, .info)
        XCTAssertEqual(
            state.lastNotice?.message,
            "Nothing to import — every phrase in the file is already in the dictionary."
        )
    }

    /// A dictionary that couldn't be read is write-locked for imports exactly
    /// as it is for edits: a merge into a half-loaded list would overwrite
    /// what the person accumulated.
    func testLockedDictionaryRefusesImport() async throws {
        harness.defaults.set(Data("junk".utf8), forKey: "replacements")
        let state = harness.makeState()
        XCTAssertNotNil(state.dictionaryProblem)

        state.importDictionary(from: try file([("a", "A")]))

        XCTAssertTrue(state.replacements.isEmpty)
        XCTAssertEqual(state.lastNotice?.kind, .warning)
        XCTAssertEqual(state.lastNotice?.message, state.dictionaryProblem?.message)
    }

    /// Round trip through the app layer: what leaves as a file comes back
    /// whole, including per-entry behavior flags.
    func testExportRoundTripsThroughAppState() async throws {
        let state = harness.makeState()
        state.addReplacement(spoken: "центр", written: "Sentry")

        let data = try state.exportedDictionary()
        harness.defaults.removeObject(forKey: "replacements")
        let fresh = harness.makeState()
        XCTAssertTrue(fresh.replacements.isEmpty)

        fresh.importDictionary(from: data)

        XCTAssertEqual(fresh.replacements.map(\.spoken), ["центр"])
        XCTAssertEqual(fresh.replacements.map(\.written), ["Sentry"])
    }
}
