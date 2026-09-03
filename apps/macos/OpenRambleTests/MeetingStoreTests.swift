import DictationAudio
import DictationCore
import XCTest

final class MeetingStoreTests: XCTestCase {
    private var root: URL!
    private var trashed: [URL] = []
    private var store: MeetingStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "meeting-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let box = UncheckedBox<[URL]>([])
        store = MeetingStore(root: root) { url in
            box.value.append(url)
            try FileManager.default.removeItem(at: url)
        }
        trashedBox = box
    }

    private var trashedBox: UncheckedBox<[URL]>!

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func metadata(startedAt: Date = Date(), title: String? = nil) -> MeetingRecordingMetadata {
        MeetingRecordingMetadata(
            startedAt: startedAt,
            duration: 12,
            title: title,
            systemAudio: SystemAudioSummary(wasRequested: false),
            endReason: .stoppedByUser
        )
    }

    /// A recording as `MeetingCapture` leaves it: audio and peaks in the
    /// incomplete directory, header sealed or not.
    private func writeAudio(for id: UUID, frames: Int, sealed: Bool) throws {
        let writer = MeetingWriter(directory: store.incompleteDirectory(for: id))
        try FileManager.default.createDirectory(at: store.incompleteDirectory(for: id), withIntermediateDirectories: true)
        try writer.open()
        try writer.append(
            microphone: [Float](repeating: 0.5, count: frames),
            system: [Float](repeating: 0, count: frames)
        )
        if sealed { try writer.finish() } else { writer.abandon() }
    }

    func testAnEmptyRootListsNothingAndOccupiesNothing() {
        XCTAssertEqual(store.list(), [])
        XCTAssertEqual(store.totalBytes(), 0)
    }

    func testAPublishedRecordingIsListedNewestFirst() throws {
        let older = metadata(startedAt: Date(timeIntervalSince1970: 1_000))
        let newer = metadata(startedAt: Date(timeIntervalSince1970: 2_000))
        try store.write(older)
        try store.write(newer)
        XCTAssertEqual(store.list().map(\.id), [newer.id, older.id])
    }

    func testAnIncompleteRecordingIsNotListedUntilPublished() throws {
        let recording = metadata()
        try store.write(recording, incomplete: true)
        try writeAudio(for: recording.id, frames: 1_600, sealed: true)
        XCTAssertEqual(store.list(), [])
        XCTAssertNil(store.audioURL(for: recording.id))

        try store.publish(recording.id)
        XCTAssertEqual(store.list().map(\.id), [recording.id])
        XCTAssertNotNil(store.audioURL(for: recording.id))
        XCTAssertNotNil(store.peaksURL(for: recording.id))
        XCTAssertGreaterThan(store.totalBytes(), 6_400)
    }

    func testStrayFilesAndDirectoriesInTheRootAreIgnored() throws {
        try Data().write(to: root.appending(path: ".DS_Store"))
        try FileManager.default.createDirectory(at: root.appending(path: "not-a-uuid"), withIntermediateDirectories: true)
        try store.write(metadata())
        XCTAssertEqual(store.list().count, 1)
    }

    func testRenameKeepsEverythingElseAndTreatsBlankAsNoTitle() throws {
        let recording = metadata(title: "Weekly sync")
        try store.write(recording)
        let renamed = try XCTUnwrap(store.rename(recording.id, title: "  Budget review  "))
        XCTAssertEqual(renamed.title, "Budget review")
        XCTAssertEqual(renamed.duration, 12)
        XCTAssertEqual(store.metadata(for: recording.id)?.title, "Budget review")
        XCTAssertNil(try store.rename(recording.id, title: "   ")?.title)
    }

    func testTrashHandsTheWholeDirectoryToTheTrasher() throws {
        let recording = metadata()
        try store.write(recording)
        try store.trash(recording.id)
        XCTAssertEqual(trashedBox.value, [store.directory(for: recording.id)])
        XCTAssertEqual(store.list(), [])
    }

    func testACrashedRecordingIsRepairedAndPublishedWithItsRealDuration() throws {
        var recording = metadata()
        recording.duration = 0
        recording.endReason = nil
        recording.transcriptionState = .live
        try store.write(recording, incomplete: true)
        try writeAudio(for: recording.id, frames: 32_000, sealed: false)

        let recovered = store.recoverIncomplete()
        XCTAssertEqual(recovered.map(\.id), [recording.id])
        XCTAssertEqual(recovered.first?.duration, 2)
        XCTAssertEqual(recovered.first?.endReason, .crashRecovered)
        XCTAssertEqual(recovered.first?.transcriptionState, .partial)
        XCTAssertEqual(store.list().map(\.id), [recording.id])
        XCTAssertEqual(MeetingWriter.frameCount(at: try XCTUnwrap(store.audioURL(for: recording.id))), 32_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.incompleteDirectory(for: recording.id).path))
    }

    func testACrashedRecordingWithoutMetadataStillComesBack() throws {
        let id = UUID()
        try writeAudio(for: id, frames: 16_000, sealed: false)
        let recovered = store.recoverIncomplete()
        XCTAssertEqual(recovered.map(\.id), [id])
        XCTAssertEqual(recovered.first?.duration, 1)
        XCTAssertNil(recovered.first?.title)
    }

    func testAnIncompleteDirectoryWithNoAudioIsSweptNotPublished() throws {
        let recording = metadata()
        try store.write(recording, incomplete: true)
        XCTAssertEqual(store.recoverIncomplete(), [])
        XCTAssertEqual(store.list(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.incompleteDirectory(for: recording.id).path))
    }

    func testARecordingStillHeldByAnotherProcessIsLeftAlone() throws {
        let recording = metadata()
        try store.write(recording, incomplete: true)
        let directory = store.incompleteDirectory(for: recording.id)
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        try writer.append(microphone: [Float](repeating: 0.1, count: 1_600), system: [Float](repeating: 0, count: 1_600))
        // Still open: the lease is held, as it would be by a live sibling.
        XCTAssertEqual(store.recoverIncomplete(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try writer.finish()
    }

    func testTranscriptRoundTripsBesideTheAudio() throws {
        let recording = metadata()
        try store.write(recording)
        let transcript = MeetingTranscript(
            utterances: [MeetingUtterance(channel: .microphone, start: 0, end: 2, text: "Hello")],
            decodedFrames: [.microphone: 32_000]
        )
        try store.write(transcript, for: recording.id)
        XCTAssertEqual(store.transcript(for: recording.id), transcript)
    }

    func testADamagedMetadataFileIsSkippedNotFatal() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: store.directory(for: id), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.directory(for: id).appending(path: "meta.json"))
        XCTAssertNil(store.metadata(for: id))
        XCTAssertEqual(store.list(), [])
    }
}
