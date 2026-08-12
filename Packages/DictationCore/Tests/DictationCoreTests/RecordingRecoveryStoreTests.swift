import XCTest
@testable import DictationCore

final class RecordingRecoveryStoreTests: XCTestCase {
    private var root: URL!
    private var takes: URL!
    private var recovered: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "recording-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        takes = root.appending(path: "Takes", directoryHint: .isDirectory)
        recovered = root.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func take(_ name: String, bytes: Int = 8) throws -> URL {
        let url = takes.appending(path: name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    /// Header that WAVWriter managed to write before process kill: format
    /// is already valid, but the dimensions are still zero, although the PCM payload is on disk.
    private func abandonedWAV(_ name: String, sampleBytes: Int = 3200) throws -> URL {
        var data = Data()
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        u32(36) // process died before the final close
        data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16)
        u16(1)
        u16(1)
        u32(16_000)
        u32(32_000)
        u16(2)
        u16(16)
        data.append(contentsOf: "data".utf8)
        u32(0) // process died before the final close
        data.append(Data(repeating: 7, count: sampleBytes))
        let url = takes.appending(path: name)
        try data.write(to: url)
        return url
    }

    func testPreserveMovesWAVOutOfActiveTakes() async throws {
        let source = try take("failed.wav")
        let store = RecordingRecoveryStore(directory: recovered)

        let preserved = try await store.preserve(source)
        let destination = try XCTUnwrap(preserved)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 7, count: 8))
    }

    func testImportAbandonedKeepsCrashRecordingForRetry() async throws {
        _ = try abandonedWAV("crash.wav", sampleBytes: 32_000)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)
        let recordings = result.recordings

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(result.discardedCorruptCount, 0)
        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
        let data = try Data(contentsOf: XCTUnwrap(recordings.first))
        let riffSize = data[4..<8].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        let payloadSize = data[40..<44].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(riffSize, 36 + 32_000)
        XCTAssertEqual(payloadSize, 32_000)
    }

    func testCorruptFragmentDoesNotBlockValidCrashRecording() async throws {
        let corrupt = try take("corrupt.wav", bytes: 10)
        _ = try abandonedWAV("valid.wav", sampleBytes: 32_000)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.discardedCorruptCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
    }

    /// A too-short fragment is not "a recording after a failure" — it is an
    /// accidental key press that outlived a kill. The main dictation path
    /// deletes such takes silently; the import must behave the same. Otherwise
    /// the next launch shows "a recording is waiting" whose retry forever
    /// hits an empty result — an error out of thin air.
    func testImportDeletesTooShortFragmentSilently() async throws {
        _ = try abandonedWAV("blip.wav", sampleBytes: 3200) // 0.1 s — below the minimum
        _ = try abandonedWAV("empty.wav", sampleBytes: 0) // header without a single frame
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertEqual(
            result.discardedCorruptCount, 0,
            "A fragment is not corruption: no reason to scare with a damage message"
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: recovered.path)) ?? []
        XCTAssertTrue(saved.filter { $0.hasSuffix(".wav") }.isEmpty)
    }

    /// Exactly at the minimum — already recognizable, keep it.
    func testImportKeepsFragmentAtMinimumDuration() async throws {
        let minimumBytes = Int(DictationDurationPolicy.minimum * 32_000)
        _ = try abandonedWAV("edge.wav", sampleBytes: minimumBytes)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.newlyImportedCount, 1)
    }

    /// A leftover from last week is not an event of this launch.
    ///
    /// The app used to announce "a recording was found after an interruption"
    /// on every start, even when the failure was a week old and nothing new
    /// happened: the person saw an error where there was none. The count of
    /// new imports lets the app tell "just rescued" from "old leftover".
    func testLeftoverFromPreviousLaunchIsNotCountedAsNew() async throws {
        let store = RecordingRecoveryStore(directory: recovered)
        _ = try await store.preserve(try take("old.wav", bytes: 64_000))

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertEqual(result.discardedCorruptCount, 0)
    }

    func testLimitsCountAndBytesOldestFirst() async throws {
        let store = RecordingRecoveryStore(
            directory: recovered,
            maximumCount: 2,
            maximumBytes: 12
        )
        for index in 0..<3 {
            let source = try take("\(index).wav", bytes: 6)
            _ = try await store.preserve(source)
            try await Task.sleep(for: .milliseconds(10))
        }

        let recordings = try await store.recordings()

        XCTAssertEqual(recordings.count, 2)
        let total = try recordings.reduce(0) {
            $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(total, 12)
    }

    func testDeletesEntriesOlderThanSevenDays() async throws {
        let store = RecordingRecoveryStore(directory: recovered)
        let old = try take("old.wav")
        _ = try await store.preserve(old)
        let before = try await store.recordings()
        let saved = try XCTUnwrap(before.first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: saved.path
        )

        _ = try await store.preserve(try take("new.wav"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        let remaining = try await store.recordings()
        XCTAssertEqual(remaining.count, 1)
    }

    /// Launch enforces retention even when nothing new is preserved.
    ///
    /// Preserving prunes too, but a quiet machine may not preserve anything
    /// for weeks — the import pass at launch is what keeps the retention
    /// promise ("kept for a few days") true.
    func testImportPrunesExpiredRecordingsWithoutNewPreserves() async throws {
        let store = RecordingRecoveryStore(directory: recovered)
        _ = try await store.preserve(try take("old.wav"))
        let before = try await store.recordings()
        let saved = try XCTUnwrap(before.first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: saved.path
        )

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        let remaining = try await store.recordings()
        XCTAssertTrue(remaining.isEmpty, "an expired recording must not outlive launch")
    }
}
