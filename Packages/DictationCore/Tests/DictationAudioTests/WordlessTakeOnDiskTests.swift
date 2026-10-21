import AVFoundation
import DictationCore
import XCTest
@testable import DictationAudio

/// A take with no words, on the production file path: the real WAV writer,
/// the real disk gate, the real rebuild from samples. Only one disk write is
/// slowed, the way a busy disk slows it.
///
/// The take's own writer holds the disk gate while it writes, so a rebuild
/// from the samples cannot run beside it. History has to wait for that
/// writer, and the person must not wait with it.
@MainActor
final class WordlessTakeOnDiskTests: XCTestCase {
    private var directory: URL!
    private var archived: [AVAudioFramePosition?] = []
    private var notices: [String] = []
    private var failures: [DictationFailureStage] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "wordless-disk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        archived = []
        notices = []
        failures = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A disk a second slow is a busy disk, not a broken one. The take
    /// reaches History whole once its writer is done, and the person is free
    /// to speak again long before that.
    func testAWordlessTakeWhoseOwnWriterIsSlowReachesHistoryWhole() async throws {
        let capture = SlowWriterCapture(directory: directory, slowWrite: .seconds(1))
        let controller = makeController(capture: capture)

        let released = try await dictate(controller)
        XCTAssertLessThan(released.duration(to: .now), .milliseconds(600), "the person waited on the disk")

        try await waitUntil(.seconds(5)) { !self.archived.isEmpty }
        XCTAssertEqual(archived, [32_001], "History gets the whole take")
        XCTAssertEqual(failures, [], "a slow disk did not lose the take")
        XCTAssertEqual(notices, ["Nothing was recognized — nothing was inserted."], "no claim the take was lost")
        try await waitUntil(.seconds(2)) {
            !FileManager.default.fileExists(atPath: self.directory.appending(path: "take.wav").path)
        }
    }

    /// A writer that does not finish in time leaves the take where automatic
    /// recovery looks for it. The loss of the History row is journaled; the
    /// recording itself is not deleted.
    func testAWordlessTakeWhoseWriterNeverFinishesIsLeftForAutomaticRecovery() async throws {
        let capture = SlowWriterCapture(directory: directory, slowWrite: .seconds(2))
        let controller = makeController(capture: capture, recordingReadableDeadline: .milliseconds(400))

        _ = try await dictate(controller)

        try await waitUntil(.seconds(5)) { !self.failures.isEmpty }
        XCTAssertEqual(failures, [.readableFile])
        XCTAssertEqual(archived, [])
        XCTAssertEqual(notices, ["Nothing was recognized — nothing was inserted."])
        // The writer finishes after everyone gave up on it; its file stays.
        try await Task.sleep(for: .seconds(2))
        let take = directory.appending(path: "take.wav")
        XCTAssertEqual(try? AVAudioFile(forReading: take).length, 32_001, "the take was deleted")
    }

    private func makeController(
        capture: any AudioCapturing,
        recordingReadableDeadline: Duration = .seconds(10)
    ) -> DictationController {
        let nothing = ASRResult(text: "", audioDuration: 2, processingDuration: 0.1)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in nothing },
            transcribeSamples: { _ in nothing },
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            recordingReadableDeadline: recordingReadableDeadline
        )
        controller.onTakeFinished = { [weak self] _, url in
            self?.archived.append(try? AVAudioFile(forReading: url).length)
            return true
        }
        controller.onNotice = { [weak self] in self?.notices.append($0.message) }
        controller.onStageFailure = { [weak self] stage, _, _ in self?.failures.append(stage) }
        return controller
    }

    /// One take; returns the moment the key came up.
    private func dictate(_ controller: DictationController) async throws -> ContinuousClock.Instant {
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        try await waitUntil(.seconds(2)) { controller.state == .listening }
        let released = ContinuousClock.now
        controller.stop()
        try await waitUntil(.seconds(5)) { controller.state == .idle }
        try await waitUntil(.seconds(2)) { !self.notices.isEmpty }
        return released
    }

    private func waitUntil(_ limit: Duration, _ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: limit)
        while !predicate(), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate())
    }
}

/// Two seconds of room tone and a click, recorded the production way: the
/// samples into the bounded memory copy, the same samples through the frame
/// sink into a WAV writer, then finalized as the microphone finalizes them.
/// The writer's first payload write takes `slowWrite`, holding the disk gate
/// the whole time, as a real write does.
private actor SlowWriterCapture: AudioCapturing {
    private let directory: URL
    private let slowWrite: Duration
    private var disposition = RecordingDisposition()

    init(directory: URL, slowWrite: Duration) {
        self.directory = directory
        self.slowWrite = slowWrite
    }

    func startRecording() async throws -> URL { directory.appending(path: "take.wav") }

    func startRecording(session: DictationSessionID, disposition: RecordingDisposition) async throws -> URL {
        self.disposition = disposition
        let url = try await startRecording()
        disposition.register([url])
        return url
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        throw AudioCaptureError.writeFailed("file-only stop is not used")
    }

    func freezeRecording() async throws -> CapturedRecording {
        let writes = WriteCounter()
        let pause = Double(slowWrite.components.seconds) + Double(slowWrite.components.attoseconds) / 1e18
        let writer = WAVWriter(url: directory.appending(path: "take.wav"), dataWriter: { handle, data in
            // The first write is the header at open; the second is the first audio.
            if writes.next() == 2 { Thread.sleep(forTimeInterval: pause) }
            try handle.write(contentsOf: data)
        })
        try writer.open()
        let disk = RecordingDiskState(writer: writer) { _ in }
        let sink = FrameSink()
        let enqueue = sink.start { disk.append($0) }
        let attachment = RecordingDiskAttachment {}
        _ = attachment.attach(RecordingDiskPipeline(writer: writer, disk: disk, sink: sink, enqueue: enqueue))
        let pcm = RecordingPCMBuffer(maximumSamples: 5 * 60 * 16_000)
        let room = [Float](repeating: 0.001, count: 16_000)
        for chunk in [room, [0.1] + room] {
            let frame = pcm.beginFrame()!
            _ = attachment.append(chunk, frame: frame, at: .now, to: pcm)
            pcm.endFrame()
        }
        let frozen = await pcm.freeze()
        let pipeline = attachment.takePipeline()!
        return finalizeCapturedRecording(
            url: writer.fileURL,
            writer: writer,
            disk: disk,
            sink: pipeline.sink,
            frozen: frozen,
            sampleRate: 16_000,
            disposition: disposition
        )
    }

    func abortRecording() async {}
}

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class NullInserter: TextInserting, @unchecked Sendable {
    func frontmostApplication() -> TargetApplication? { nil }
    func insert(_ text: String, into application: TargetApplication?) async throws {}
    func pressReturn() async throws {}
}

private final class NullOverlay: OverlayPresenting, @unchecked Sendable {
    func present(_ state: DictationState, elapsed: TimeInterval) async {}
    func presentNotice(_ notice: DictationNotice) async {}
    func dismiss() async {}
}

private final class NullSounds: Sounding, @unchecked Sendable {
    func playAttention() async {}
}
