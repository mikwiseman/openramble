import XCTest

/// The history is the first thing in this product that keeps dictated text
/// after quit. It has to survive a relaunch, stay bounded, and take its audio
/// with it when an entry goes.
final class DictationHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: DictationHistoryStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "history-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = DictationHistoryStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeAudio(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try Data("fake wav".utf8).write(to: url)
        return url
    }

    // MARK: - Persistence

    /// The point of the feature: it is still there after quit.
    ///
    /// This also catches a mismatch between how entries are written and how
    /// they are read — an encoder and decoder that disagree about dates lose
    /// the entire history at the next launch, silently and with no error.
    func testEntriesSurviveAReload() throws {
        _ = try store.record(text: "first take", audio: nil, limit: 5)
        _ = try store.record(text: "second take", audio: nil, limit: 5)

        let reopened = DictationHistoryStore(directory: directory).load()
        XCTAssertEqual(reopened.map(\.text), ["second take", "first take"])
        XCTAssertNotNil(reopened.first?.date)
    }

    func testNewestEntryComesFirst() throws {
        _ = try store.record(text: "older", audio: nil, limit: 5)
        let entries = try store.record(text: "newer", audio: nil, limit: 5)
        XCTAssertEqual(entries.first?.text, "newer")
    }

    /// Empty text is not a dictation. Recording it would fill the list with
    /// blank rows after every silent take.
    func testBlankTextIsNotRecorded() throws {
        let entries = try store.record(text: "   \n ", audio: nil, limit: 5)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Retention

    func testTheListIsTrimmedToTheLimit() throws {
        for index in 0..<8 {
            _ = try store.record(text: "take \(index)", audio: nil, limit: 5)
        }
        XCTAssertEqual(store.load().count, 5)
        XCTAssertEqual(store.load().first?.text, "take 7")
    }

    /// Audio is the expensive part. An entry that falls off the end must not
    /// leave its recording behind, or the folder grows without bound while the
    /// list looks correctly short.
    func testEvictedEntriesTakeTheirAudioWithThem() throws {
        let first = try makeAudio("first-source.wav")
        _ = try store.record(text: "oldest", audio: first, limit: 1)
        let storedName = try XCTUnwrap(store.load().first?.audioFileName)
        let storedURL = directory.appending(path: storedName, directoryHint: .notDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))

        _ = try store.record(text: "newest", audio: nil, limit: 1)

        XCTAssertEqual(store.load().map(\.text), ["newest"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storedURL.path),
            "the evicted take's audio is still on disk"
        )
    }

    /// Lowering the setting has to take effect on what is already stored, not
    /// only on what arrives next.
    func testLoweringTheLimitTrimsWhatIsAlreadyThere() throws {
        for index in 0..<6 {
            _ = try store.record(text: "take \(index)", audio: nil, limit: 10)
        }
        let trimmed = try store.applyLimit(2)
        XCTAssertEqual(trimmed.count, 2)
        XCTAssertEqual(store.load().map(\.text), ["take 5", "take 4"])
    }

    // MARK: - Deleting

    func testDeletingAnEntryRemovesItAndItsAudio() throws {
        let audio = try makeAudio("source.wav")
        _ = try store.record(text: "keep", audio: nil, limit: 5)
        _ = try store.record(text: "remove", audio: audio, limit: 5)

        let target = try XCTUnwrap(store.load().first { $0.text == "remove" })
        let storedURL = try XCTUnwrap(store.audioURL(for: target))

        let remaining = try store.delete(target)
        XCTAssertEqual(remaining.map(\.text), ["keep"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }

    func testDeletingEverythingLeavesNothingBehind() throws {
        let audio = try makeAudio("source.wav")
        _ = try store.record(text: "one", audio: audio, limit: 5)
        _ = try store.record(text: "two", audio: nil, limit: 5)

        try store.deleteAll()
        XCTAssertTrue(store.load().isEmpty)
        let leftover = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".wav") && $0 != "source.wav" }
        XCTAssertTrue(leftover.isEmpty, "audio left behind: \(leftover)")
    }

    // MARK: - Audio that is not there

    /// A record whose file has gone is still worth showing: the text is the
    /// part people came for.
    func testAnEntryWithoutAudioStillLoads() throws {
        _ = try store.record(text: "text only", audio: nil, limit: 5)
        let entry = try XCTUnwrap(store.load().first)
        XCTAssertNil(store.audioURL(for: entry))
        XCTAssertEqual(entry.text, "text only")
    }

    func testAMissingAudioFileIsReportedAsAbsent() throws {
        let audio = try makeAudio("source.wav")
        _ = try store.record(text: "with audio", audio: audio, limit: 5)
        let entry = try XCTUnwrap(store.load().first)
        try FileManager.default.removeItem(at: try XCTUnwrap(store.audioURL(for: entry)))
        XCTAssertNil(store.audioURL(for: entry))
    }

    // MARK: - The setting

    func testTheStoredLimitFallsBackToTheDefault() throws {
        let suite = "is.waiwai.dictation.tests.history-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(DictationHistoryStore.storedLimit(in: defaults), 5)

        defaults.set(0, forKey: DictationHistoryStore.limitKey)
        XCTAssertEqual(
            DictationHistoryStore.storedLimit(in: defaults),
            5,
            "zero would mean keeping nothing, which is not what the setting offers"
        )

        defaults.set(20, forKey: DictationHistoryStore.limitKey)
        XCTAssertEqual(DictationHistoryStore.storedLimit(in: defaults), 20)

        defaults.set(10_000, forKey: DictationHistoryStore.limitKey)
        XCTAssertEqual(
            DictationHistoryStore.storedLimit(in: defaults),
            DictationHistoryStore.maximumLimit,
            "the number has to stay finite"
        )
    }

    /// A truncated or hand-edited index must not take the app down.
    func testACorruptIndexReadsAsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8)
            .write(to: directory.appending(path: "history.json", directoryHint: .notDirectory))
        XCTAssertTrue(store.load().isEmpty)
    }
}
