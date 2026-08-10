import AVFoundation
import XCTest
@testable import DictationAudio

/// The recording is the only copy of what was said.
///
/// The sound comes from the audio stream, and the “stop” and “cancel” commands come from the main one
/// stream, so recording and completion always go towards each other. All,
/// what is being checked here is about data loss: silently lost bytes
/// look like a truncated phrase, and they are usually attributed to recognition.
final class WAVWriterRobustnessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wav-robust-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWriter(name: String = "take.wav") -> WAVWriter {
        WAVWriter(url: directory.appending(path: name), sampleRate: 16_000, channels: 1)
    }

    // MARK: - Simultaneous recording

    func testConcurrentAppendsLoseNothing() async throws {
        // Portions of sound come from the audio stream, but there is more than one: change device
        // on the go or restarting the engine gives an overlay. Counter without lock
        // the recorded one is separated from the file, and the header declares the length,
        // which is not in the file - recognition reads the truncated record.
        let writer = makeWriter()
        try writer.open()

        let writers = 8
        let chunksEach = 50
        let chunk = Array(repeating: Float(0.25), count: 160)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<writers {
                group.addTask {
                    for _ in 0..<chunksEach {
                        try? writer.append(chunk)
                    }
                }
            }
        }

        let expectedSamples = writers * chunksEach * chunk.count
        XCTAssertEqual(writer.duration, Double(expectedSamples) / 16_000, accuracy: 0.0001)

        let url = try writer.close()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(
            data.count,
            44 + expectedSamples * 2,
            "\u{041A}\u{0430}\u{0436}\u{0434}\u{0430}\u{044F} \u{043F}\u{043E}\u{0440}\u{0446}\u{0438}\u{044F} \u{0437}\u{0432}\u{0443}\u{043A}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{0434}\u{043E}\u{0439}\u{0442}\u{0438} \u{0434}\u{043E} \u{0444}\u{0430}\u{0439}\u{043B}\u{0430} \u{0446}\u{0435}\u{043B}\u{0438}\u{043A}\u{043E}\u{043C}"
        )

        // And the file after the race remains readable by the system, and not “almost WAV”.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, Int64(expectedSamples))
    }

    // MARK: - Life cycle

    func testAppendAfterCloseIsRefused() throws {
        // The tail of the sound that came after stopping will not end up in the closed file.
        // To accept it silently means to lose a piece of the phrase without a single trace.
        let writer = makeWriter()
        try writer.open()
        try writer.append([0.1, 0.2])
        try writer.close()

        XCTAssertThrowsError(try writer.append([0.3])) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }
    }

    func testSecondCloseIsRefused() throws {
        // Stopping can occur twice: when the key is released and when the limit is reached
        // duration. The second closure must be a refusal, not a repeat
        // rewriting the header over the finished file.
        let writer = makeWriter()
        try writer.open()
        try writer.append(Array(repeating: 0.1, count: 100))
        try writer.close()

        XCTAssertThrowsError(try writer.close()) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }

        // The file remains intact.
        let file = try AVAudioFile(forReading: writer.fileURL)
        XCTAssertEqual(file.length, 100)
    }

    func testDiscardWithoutOpenDoesNothingBad() {
        // Cancel comes from any state, including before the file
        // managed to appear. You can't fall on this.
        let writer = makeWriter()

        writer.discard()
        writer.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.fileURL.path))
    }

    func testReopeningStartsTheRecordingFromScratch() throws {
        // The repeated session should not be appended to the previous record: otherwise in
        // recognition will remove someone else's phrase spoken a minute ago.
        let writer = makeWriter()
        try writer.open()
        try writer.append(Array(repeating: 0.5, count: 1000))
        try writer.close()

        try writer.open()
        try writer.append(Array(repeating: 0.5, count: 10))
        let url = try writer.close()

        XCTAssertEqual(writer.duration, 10.0 / 16_000, accuracy: 0.0001)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 20, "\u{0421}\u{0442}\u{0430}\u{0440}\u{0430}\u{044F} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0431}\u{044B}\u{0442}\u{044C} \u{0437}\u{0430}\u{0442}\u{0451}\u{0440}\u{0442}\u{0430}, \u{0430} \u{043D}\u{0435} \u{043F}\u{0440}\u{043E}\u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D}\u{0430}")
    }

    // MARK: - Failure at start

    func testOpenFailsLoudlyWhenTheDirectoryIsBlocked() throws {
        // There is a file in place of the records folder - this happens after manual fiddling with
        // Finder. The dictation must say this, and not start “recording”,
        // which has nowhere to go.
        let blocker = directory.appending(path: "blocked", directoryHint: .notDirectory)
        try Data("\u{0437}\u{0430}\u{043D}\u{044F}\u{0442}\u{043E}".utf8).write(to: blocker)
        let writer = WAVWriter(url: blocker.appending(path: "take.wav"))

        XCTAssertThrowsError(try writer.open()) { error in
            guard case .cannotCreateFile = error as? WAVWriter.Failure else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} \u{043E}\u{0442}\u{043A}\u{0430}\u{0437} \u{0441}\u{043E}\u{0437}\u{0434}\u{0430}\u{043D}\u{0438}\u{044F} \u{0444}\u{0430}\u{0439}\u{043B}\u{0430}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    // MARK: - Ran out of space

    func testDiskFullIsReportedInsteadOfSilentlyLosingSound() throws {
        // “Disk space has run out” in the middle of a dictation. Real write failure
        // reproduced with a file size limit: the kernel responds exactly the same
        // failure, same as a full disk.
        //
        // The main thing is checked: the failure is visible. Silently lost bytes are
        // a truncated phrase that a person will not notice right away and will write off as
        // recognition.
        var saved = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &saved), 0)
        // Without this, exceeding the limit kills the process with a signal, not an error.
        signal(SIGXFSZ, SIG_IGN)
        var limited = saved
        limited.rlim_cur = 8192
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &limited), 0)
        defer { setrlimit(RLIMIT_FSIZE, &saved) }

        let writer = makeWriter()
        try writer.open()

        // Fit: 44 bytes of header plus 2000 samples of two bytes.
        try writer.append(Array(repeating: 0.1, count: 2000))
        let survivedDuration = writer.duration

        XCTAssertThrowsError(try writer.append(Array(repeating: 0.1, count: 100_000))) { error in
            guard case .writeFailed = error as? WAVWriter.Failure else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} \u{043E}\u{0442}\u{043A}\u{0430}\u{0437} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }

        XCTAssertEqual(
            writer.duration,
            survivedDuration,
            "\u{0414}\u{043B}\u{0438}\u{0442}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E}\u{0441}\u{0442}\u{044C} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{0441}\u{0447}\u{0438}\u{0442}\u{0430}\u{0442}\u{044C} \u{0442}\u{043E}\u{043B}\u{044C}\u{043A}\u{043E} \u{0442}\u{043E}, \u{0447}\u{0442}\u{043E} \u{0434}\u{0435}\u{0439}\u{0441}\u{0442}\u{0432}\u{0438}\u{0442}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E} \u{043B}\u{0435}\u{0433}\u{043B}\u{043E} \u{043D}\u{0430} \u{0434}\u{0438}\u{0441}\u{043A}"
        )

        // The file remains honest after refusal: the header describes exactly those
        // readings that were recorded, not those that were sent.
        let url = try writer.close()
        setrlimit(RLIMIT_FSIZE, &saved)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 2000)
    }

    // MARK: - Extreme dimensions

    func testEmptyChunkChangesNothing() throws {
        // The audio stream produces an empty buffer when paused - this is normal.
        let writer = makeWriter()
        try writer.open()
        try writer.append([])
        try writer.append([0.1])
        try writer.append([])
        let url = try writer.close()

        XCTAssertEqual(try Data(contentsOf: url).count, 44 + 2)
    }

    func testLongRecordingKeepsHeaderAndLengthConsistent() throws {
        // A minute of speech is the usual length of a working dictation, and a heading with dimensions
        // in megabytes should remain true: the system reads the length exactly
        // from there, and not from the actual file.
        let writer = makeWriter()
        try writer.open()

        let second = (0..<16_000).map { sin(Float($0) * 0.01) * 0.3 }
        for _ in 0..<60 { try writer.append(second) }
        let url = try writer.close()

        XCTAssertEqual(writer.duration, 60, accuracy: 0.001)

        let data = try Data(contentsOf: url)
        let expectedBytes = 60 * 16_000 * 2
        let riffSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(riffSize), 36 + expectedBytes)
        XCTAssertEqual(Int(dataSize), expectedBytes)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, Int64(60 * 16_000))
    }
}

/// File handle after unsuccessful close.
final class WAVWriterHandleReleaseTests: XCTestCase {
    func testFailedCloseStillReleasesTheHandle() throws {
        // The file is removed from being written - this happens when cleaning the disk.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "handle-\(UUID().uuidString).wav")
        let writer = WAVWriter(url: url, sampleRate: 16_000, channels: 1)
        try writer.open()
        try writer.append(Array(repeating: 0.1, count: 1000))
        _ = try? writer.close()

        // The second closure should say "not open" rather than trying to write to
        // already closed handle.
        XCTAssertThrowsError(try writer.close()) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }
        try? FileManager.default.removeItem(at: url)
    }

    func testProcessDoesNotRunOutOfFileDescriptors() throws {
        // A thousand dictations in a row: if descriptors leak, the process will run into
        // limit and will stop opening files at all.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "fd-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<1000 {
            let writer = WAVWriter(url: directory.appending(path: "take-\(index).wav"))
            try writer.open()
            try writer.append([0.1, 0.2, 0.3])
            _ = try writer.close()
        }

        let last = WAVWriter(url: directory.appending(path: "final.wav"))
        XCTAssertNoThrow(try last.open(), "\u{0414}\u{0435}\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}\u{043E}\u{0440}\u{044B} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{043E}\u{0441}\u{0432}\u{043E}\u{0431}\u{043E}\u{0436}\u{0434}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F}")
        _ = try last.close()
    }
}
