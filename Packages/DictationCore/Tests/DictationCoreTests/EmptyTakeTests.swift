import AVFoundation
import XCTest
@testable import DictationCore

/// A take in which the model found no words is never thrown away in silence.
///
/// Sound with no words is kept for History, where it can be played and
/// recognized again. Silence is not kept — a row of nothing helps nobody — but
/// it names the microphone it came from, because a muted or wrong input is the
/// usual reason a held key records nothing.
@MainActor
final class EmptyTakeTests: XCTestCase {
    private var capture: FakeCapture!
    private var inserter: FakeInserter!
    private var overlay: FakeOverlay!
    private var sounds: FakeSounds!
    private var controller: DictationController!
    private var archived: [(text: String, url: URL)] = []
    /// What the handed-over file held at the moment of the handover, which is
    /// the only moment History gets to copy it.
    private var handedOverFrames: [AVAudioFramePosition?] = []

    /// Room noise, well under the speech floor.
    private let quiet = [Float](repeating: 0.001, count: 16_000)
    private nonisolated static let nothing = ASRResult(text: "", audioDuration: 2, processingDuration: 0.1)

    override func setUp() async throws {
        capture = FakeCapture()
        inserter = FakeInserter()
        overlay = FakeOverlay()
        sounds = FakeSounds()
        archived = []
        handedOverFrames = []
        controller = makeController(capture: capture)
    }

    private func makeController(
        capture: any AudioCapturing,
        transcribeSamples: (@Sendable ([Float]) async throws -> ASRResult)? = nil
    ) -> DictationController {
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in Self.nothing },
            transcribeSamples: transcribeSamples,
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { _ in TextPipeline() }
        )
        controller.onTakeFinished = { [weak self] text, url in
            self?.archived.append((text, url))
            self?.handedOverFrames.append(try? AVAudioFile(forReading: url).length)
        }
        return controller
    }

    /// One whole take, waited on by condition rather than by a fixed number
    /// of sleeps: under load a fixed wait ends before the take does.
    private func dictate(_ controller: DictationController? = nil) async throws {
        let controller = controller ?? self.controller!
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        try await waitUntil { controller.state == .listening }
        controller.stop()
        try await waitUntil { controller.state == .idle }
        // The notice reaches the panel through its own queue, after idle.
        try await waitUntil { [overlay] in await !(overlay!.notices.isEmpty) }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied)
    }

    private func waitForOneAttentionPlay() async throws {
        try await waitUntil { [sounds] in await sounds!.attentionPlays >= 1 }
    }

    func testAnEmptyTakeWithSoundIsKeptInHistoryWithoutText() async throws {
        await capture.setBufferedSamples(quiet + [0.1] + quiet)

        try await dictate()
        try await waitForOneAttentionPlay()

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        let plays = await sounds.attentionPlays
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(archived.map(\.text), [""], "kept so it can be heard and recognized again")
        XCTAssertEqual(archived.map(\.url.lastPathComponent), ["fake-take.wav"])
        XCTAssertEqual(notices.count, 1, "\(notices)")
        XCTAssertEqual(notices.first?.kind, .info)
        XCTAssertEqual(notices.first?.message, "Nothing was recognized — nothing was inserted.")
        XCTAssertEqual(notices.first?.wordsDidNotLand, true)
        XCTAssertEqual(plays, 1)
    }

    /// Takes under five minutes are recognized from memory, so nothing waits
    /// for the file before the words come back. When the file never reached
    /// disk — the writer slot was busy, or the writer failed — History must
    /// still get a whole, playable recording, rebuilt from the samples, and
    /// that rebuilt copy must not stay behind for recovery to adopt.
    func testAWordlessTakeWhoseFileNeverReachedDiskIsKeptFromItsSamples() async throws {
        let takes = FileManager.default.temporaryDirectory
            .appending(path: "wordless-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: takes) }
        let samples = quiet + [0.1] + quiet
        let controller = makeController(
            capture: try MemoryOnlyCapture(directory: takes, samples: samples),
            transcribeSamples: { _ in Self.nothing }
        )

        try await dictate(controller)

        XCTAssertEqual(archived.map(\.text), [""])
        XCTAssertEqual(
            handedOverFrames,
            [AVAudioFramePosition(samples.count)],
            "History gets the whole take while it still exists"
        )
        let notices = await overlay.notices
        XCTAssertEqual(notices.map(\.message), ["Nothing was recognized — nothing was inserted."])
        try await waitUntil {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: takes.path)) ?? []
            return !names.contains { $0.hasPrefix("memory-recovery-") }
        }
    }

    /// A writer that never finishes must not hold the next take hostage.
    /// Someone told "nothing was recognized" says it again a few seconds
    /// later, and the samples are already whole in memory, so History gets
    /// them without waiting on the disk.
    func testAWordlessTakeDoesNotWaitForAWedgedWriter() async throws {
        let takes = FileManager.default.temporaryDirectory
            .appending(path: "wedged-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: takes) }
        let samples = quiet + [0.1] + quiet
        let controller = makeController(
            capture: try MemoryOnlyCapture(directory: takes, samples: samples, writerWedged: true),
            transcribeSamples: { _ in Self.nothing }
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        try await waitUntil { controller.state == .listening }
        let released = ContinuousClock.now
        controller.stop()
        try await waitUntil { controller.state == .idle }
        XCTAssertLessThan(released.duration(to: .now), .seconds(2), "the take waited on the writer")

        try await Task.sleep(until: released.advanced(by: .seconds(1)), clock: .continuous)
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        try await waitUntil { controller.state == .listening }
        controller.cancel()
        try await waitUntil { controller.state == .idle }

        XCTAssertEqual(archived.map(\.text), [""])
        XCTAssertEqual(
            handedOverFrames,
            [AVAudioFramePosition(samples.count)],
            "History gets the whole take while it still exists"
        )
        try await waitUntil {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: takes.path)) ?? []
            return !names.contains { $0.hasPrefix("memory-recovery-") }
        }
    }

    /// When neither the file nor a rebuild from the samples can be had, the
    /// take cannot reach History. That loss is journaled, numbers only, as the
    /// file stage failing, so it never happens in silence.
    func testAWordlessTakeThatCannotBeKeptIsJournaledAsAFileFailure() async throws {
        let takes = FileManager.default.temporaryDirectory
            .appending(path: "unkept-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: takes) }
        let controller = makeController(
            capture: try MemoryOnlyCapture(directory: takes, samples: quiet + [0.1] + quiet, rebuildFails: true),
            transcribeSamples: { _ in Self.nothing }
        )
        var failures: [(stage: DictationFailureStage, timedOut: Bool)] = []
        controller.onStageFailure = { stage, _, timedOut in failures.append((stage, timedOut)) }

        try await dictate(controller)

        XCTAssertTrue(archived.isEmpty)
        XCTAssertEqual(failures.map(\.stage), [.readableFile], "the lost take leaves a trace")
        XCTAssertEqual(failures.map(\.timedOut), [false])
        let notices = await overlay.notices
        XCTAssertEqual(notices.map(\.message), ["Nothing was recognized — nothing was inserted."])
    }

    func testAnEmptyTakeOfSilenceNamesTheMicrophoneAndKeepsNothing() async throws {
        await capture.setBufferedSamples(quiet)
        controller.microphoneName = { "Test Mic" }

        try await dictate()
        try await waitForOneAttentionPlay()

        let notices = await overlay.notices
        let plays = await sounds.attentionPlays
        XCTAssertTrue(archived.isEmpty, "silence is not kept")
        XCTAssertEqual(notices.count, 1, "\(notices)")
        XCTAssertEqual(notices.first?.message, "Heard only silence from Test Mic.")
        // Orange: a muted, dead or wrong input needs the person to act.
        XCTAssertEqual(notices.first?.kind, .warning)
        XCTAssertEqual(notices.first?.wordsDidNotLand, true)
        XCTAssertNil(notices.first?.recoveryAudio)
        XCTAssertEqual(plays, 1)
    }

    /// Without a name the words change, never the kind: it is the same
    /// silence, and it is counted the same way.
    func testSilenceFromAnUnnamedMicrophoneSaysNothingWasRecognized() async throws {
        await capture.setBufferedSamples(quiet)
        controller.microphoneName = { nil }

        try await dictate()

        let notices = await overlay.notices
        XCTAssertTrue(archived.isEmpty)
        XCTAssertEqual(notices.map(\.message), ["Nothing was recognized — nothing was inserted."])
        XCTAssertEqual(notices.first?.kind, .warning)
        XCTAssertEqual(notices.first?.wordsDidNotLand, true)
    }

    /// Without the samples (a take longer than the in-memory bound) there is
    /// no telling silence from sound, so the take is kept.
    func testAnEmptyTakeWithoutPCMIsKeptRatherThanCalledSilence() async throws {
        await capture.setBufferedSamples(nil)
        controller.microphoneName = { "Test Mic" }

        try await dictate()

        let notices = await overlay.notices
        XCTAssertEqual(archived.map(\.text), [""])
        XCTAssertEqual(notices.map(\.message), ["Nothing was recognized — nothing was inserted."])
    }
}

/// A take that lives only in memory, like the production capture's when the
/// writer slot is busy: its file never appears, and the only way to a WAV is
/// to rebuild one from the samples, beside where the file would have been.
/// A wedged writer is the slower version of the same thing: the file is never
/// refused, it just never arrives.
///
/// The rebuilt copy is written before the take and only revealed when the
/// controller asks for it. These tests measure the controller, and a shared
/// disk that stalls past the rebuild deadline once in a while is not it.
private actor MemoryOnlyCapture: AudioCapturing {
    private let url: URL
    private let samples: [Float]
    private let writerWedged: Bool
    private let rebuildFails: Bool
    private let prepared: URL
    private let rebuilt: URL

    init(directory: URL, samples: [Float], writerWedged: Bool = false, rebuildFails: Bool = false) throws {
        url = directory.appending(path: "take.wav")
        self.samples = samples
        self.writerWedged = writerWedged
        self.rebuildFails = rebuildFails
        prepared = directory.appending(path: "prepared.wav.partial")
        rebuilt = directory.appending(path: "memory-recovery-\(UUID().uuidString).wav")
        try Self.write(samples, to: prepared)
    }

    func startRecording() async throws -> URL { url }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        throw AudioCaptureError.writeFailed("the recording file is unavailable")
    }

    func freezeRecording() async throws -> CapturedRecording {
        let unavailable = Task<URL, Error> { [writerWedged] in
            if writerWedged { try await Task.sleep(for: .seconds(120)) }
            throw AudioCaptureError.writeFailed("the recording file is unavailable")
        }
        let prepared = prepared
        let rebuilt = rebuilt
        let rebuildFails = rebuildFails
        let disposition = RecordingDisposition()
        disposition.register([rebuilt])
        return CapturedRecording(
            url: url,
            duration: Double(samples.count) / 16_000,
            samples: samples,
            disposition: disposition,
            readableTask: unavailable,
            durableTask: unavailable,
            materializeRecovery: {
                if rebuildFails { throw AudioCaptureError.writeFailed("the disk is full") }
                try FileManager.default.moveItem(at: prepared, to: rebuilt)
                return rebuilt
            }
        )
    }

    func abortRecording() async {}

    private static func write(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            throw AudioCaptureError.writeFailed("no buffer")
        }
        buffer.frameLength = count
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
