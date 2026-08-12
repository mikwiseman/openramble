import XCTest
@testable import DictationCore

/// The dictionary travels between Macs as a file: exact round-trips, honest
/// refusals for foreign files, and merges that never destroy.
final class DictionaryTransferTests: XCTestCase {
    private func replacement(
        _ spoken: String,
        _ written: String,
        inflects: Bool = true,
        noAcousticBoost: Bool = false,
        allowsPhoneticMatching: Bool = true
    ) -> DictionaryReplacement {
        DictionaryReplacement(
            spoken: spoken,
            written: written,
            inflects: inflects,
            noAcousticBoost: noAcousticBoost,
            allowsPhoneticMatching: allowsPhoneticMatching
        )
    }

    private func contents(
        _ replacements: [DictionaryReplacement]
    ) -> [[String]] {
        replacements.map {
            [$0.spoken, $0.written, "\($0.inflects)", "\($0.noAcousticBoost)", "\($0.allowsPhoneticMatching)"]
        }
    }

    // MARK: - Round-trip

    func testExportedFileImportsBackExactly() throws {
        let original = [
            replacement("poust girls", "Postgres"),
            replacement("центр", "Sentry", noAcousticBoost: true),
            replacement("комет", "commit", inflects: false, allowsPhoneticMatching: false),
        ]

        let imported = try DictionaryTransfer.read(DictionaryTransfer.export(original))

        XCTAssertEqual(contents(imported), contents(original))
    }

    /// The file carries no internal identifiers and no default-valued flags:
    /// it stays short, diffable and hand-editable.
    func testExportedFileIsPortable() throws {
        let data = try DictionaryTransfer.export([replacement("a", "b")])
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["openRambleDictionary"] as? Int, 1)
        let entries = try XCTUnwrap(object["replacements"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0]["id"], "internal ids must not leak into the file")
        XCTAssertNil(entries[0]["inflects"], "default flags stay implicit")
        XCTAssertNil(entries[0]["noAcousticBoost"], "default flags stay implicit")
        XCTAssertEqual(Set(entries[0].keys), ["spoken", "written"])
    }

    /// A minimal hand-written file — just the pairs — imports with defaults.
    func testHandWrittenFileWithBarePairsImports() throws {
        let file = """
        {"openRambleDictionary": 1, "replacements": [{"spoken": "Sentry", "written": "Sentry"}]}
        """
        let imported = try DictionaryTransfer.read(Data(file.utf8))

        XCTAssertEqual(imported.count, 1)
        XCTAssertTrue(imported[0].inflects)
        XCTAssertFalse(imported[0].noAcousticBoost)
        XCTAssertTrue(imported[0].allowsPhoneticMatching)
    }

    // MARK: - Refusals

    func testForeignJSONIsRefusedByName() {
        let foreign = Data("{\"someOtherApp\": true}".utf8)
        XCTAssertThrowsError(try DictionaryTransfer.read(foreign)) { error in
            XCTAssertEqual(error as? DictionaryTransfer.TransferError, .notADictionaryFile)
        }
    }

    func testGarbageIsReportedAsDamage() {
        XCTAssertThrowsError(try DictionaryTransfer.read(Data("not json".utf8))) { error in
            guard case .damaged = error as? DictionaryTransfer.TransferError else {
                return XCTFail("expected .damaged, got \(error)")
            }
        }
    }

    func testNewerFormatIsRefusedPolitely() {
        let future = Data("{\"openRambleDictionary\": 2, \"replacements\": []}".utf8)
        XCTAssertThrowsError(try DictionaryTransfer.read(future)) { error in
            XCTAssertEqual(error as? DictionaryTransfer.TransferError, .newerFormat(2))
        }
    }

    /// Whitespace-only entries carry no phrase — dropped, not imported.
    func testEmptyEntriesAreDropped() throws {
        let file = """
        {"openRambleDictionary": 1, "replacements": [
            {"spoken": "  ", "written": "x"},
            {"spoken": "ok", "written": " trimmed  "}
        ]}
        """
        let imported = try DictionaryTransfer.read(Data(file.utf8))

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].written, "trimmed")
    }

    // MARK: - Merge

    func testMergeAppendsNewAndUpdatesMatchesCaseInsensitively() {
        let existing = [
            replacement("sentry", "Centry"),
            replacement("deploy", "deploy"),
        ]
        let imported = [
            replacement("Sentry", "Sentry"),
            replacement("poust girls", "Postgres"),
        ]

        let merged = DictionaryTransfer.merge(existing: existing, imported: imported)

        XCTAssertEqual(merged.added, 1)
        XCTAssertEqual(merged.updated, 1)
        XCTAssertEqual(
            merged.replacements.map(\.written),
            ["Sentry", "deploy", "Postgres"],
            "updates edit in place, additions append in file order"
        )
        XCTAssertEqual(
            merged.replacements[0].id, existing[0].id,
            "an update keeps the row's identity"
        )
    }

    /// Importing a file that changes nothing reports exactly that.
    func testMergeCountsOnlyRealChanges() {
        let existing = [replacement("sentry", "Sentry")]
        let merged = DictionaryTransfer.merge(existing: existing, imported: existing)

        XCTAssertEqual(merged.added, 0)
        XCTAssertEqual(merged.updated, 0)
        XCTAssertEqual(merged.replacements, existing)
    }

    func testMergeIntoEmptyDictionaryKeepsFileOrder() {
        let imported = [
            replacement("b", "B"),
            replacement("a", "A"),
        ]
        let merged = DictionaryTransfer.merge(existing: [], imported: imported)

        XCTAssertEqual(merged.added, 2)
        XCTAssertEqual(merged.replacements.map(\.spoken), ["b", "a"])
    }
}
