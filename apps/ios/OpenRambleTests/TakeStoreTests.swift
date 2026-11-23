import XCTest
@testable import OpenRamble

@MainActor
final class TakeStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = URL.temporaryDirectory.appending(path: "takes-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTakesSurviveARelaunch() throws {
        let store = TakeStore(root: root)
        let earlier = Take(recordedAt: .now.addingTimeInterval(-60), duration: 4, text: "First.", state: .written)
        let later = Take(recordedAt: .now, duration: 2, state: .writing, audioFileName: "b.wav")
        store.insert(later)
        store.insert(earlier)

        let reopened = TakeStore(root: root)
        XCTAssertEqual(reopened.takes.map(\.id), [earlier.id, later.id], "oldest first")
        XCTAssertEqual(reopened.takes.first?.text, "First.")
        XCTAssertEqual(reopened.unfinished.map(\.id), [later.id], "a take whose writing never finished is found again")
    }

    func testDeletingATakeRemovesItsRecording() throws {
        let store = TakeStore(root: root)
        let take = Take(duration: 1, audioFileName: "x.wav")
        let audio = store.audioFolder.appending(path: "x.wav")
        try Data([1, 2, 3]).write(to: audio)
        store.insert(take)
        XCTAssertNotNil(store.audioURL(for: take))

        store.delete(take.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(TakeStore(root: root).takes.isEmpty)
    }

    func testTheFolderIsKeptOutOfICloudBackup() throws {
        _ = TakeStore(root: root)
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testAnUnreadableIndexIsSetAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appending(path: "takes.json"))

        let store = TakeStore(root: root)

        XCTAssertTrue(store.takes.isEmpty)
        XCTAssertNotNil(store.saveFailure, "the person is told")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("takes-unreadable-") }, "the old index is kept for recovery")
    }

    func testLatestWrittenSkipsTakesWithoutWords() {
        let store = TakeStore(root: root)
        let written = Take(recordedAt: .now.addingTimeInterval(-10), duration: 1, text: "Hello.", state: .written)
        let silent = Take(recordedAt: .now, duration: 1, state: .silent)
        store.insert(written)
        store.insert(silent)
        XCTAssertEqual(store.latestWritten?.id, written.id)
    }
}
