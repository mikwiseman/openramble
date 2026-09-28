import AVFoundation
import DictationCore
import Foundation
import LocalASR
import XCTest

/// Real model + real WAV across the capture memory boundary. No microphone,
/// clipboard, user recordings, or model downloads are involved.
@MainActor
final class FileBackedStreamingTests: XCTestCase {
    func testEightMinuteFileReusesAlreadyRecognizedSpeech() async throws {
        guard ProcessInfo.processInfo.environment["OPENRAMBLE_LONG_DICTATION_GATE"] == "1" else {
            throw XCTSkip("set OPENRAMBLE_LONG_DICTATION_GATE=1 with the installed model")
        }
        let transcriber = try await requireEndToEndTranscriber()
        let phrase = try await SpeechFixtures.shared.speech(
            "This recording must keep every completed section and its final words.", voice: .english)
        let voice = try AudioFileReader().samples(from: phrase)
        let segmentFrames = 20 * 16_000
        XCTAssertLessThan(voice.count, segmentFrames)
        let segment = voice + [Float](repeating: 0, count: max(0, segmentFrames - voice.count))
        let samples = Array(repeating: segment, count: 24).flatMap { $0 }
        let url = FileManager.default.temporaryDirectory.appending(path: "long-stream-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            try file.write(from: buffer)
        }
        let probe = Probe(transcriber: transcriber)
        let capture = Capture(url: url, segment: segment)
        let inserter = RecordingInserter()
        let controller = DictationController(capture: capture,
            transcribe: { _ in
                XCTFail("the eight-minute recording must not be recognized again in full")
                throw ASREngineError.cancelled
            },
            transcribeSamples: { try await probe.recognize($0) },
            readSamples: { try await AudioFileReader().samplesOnDiskQueue(from: $0) },
            inserter: inserter, overlay: RecordingOverlay(), sounds: CountingSounds())

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        let prefixDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while await probe.completed < 23, ContinuousClock.now < prefixDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let completedPrefix = await probe.completed
        XCTAssertEqual(completedPrefix, 23)
        let stop = ContinuousClock.now
        controller.stop()
        while controller.state != .idle, ContinuousClock.now < stop.advanced(by: .seconds(30)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = stop.duration(to: .now)
        XCTAssertEqual(controller.state, .idle)
        let counts = await probe.sampleCounts
        XCTAssertEqual(counts, Array(repeating: segmentFrames, count: 24))
        let texts = await probe.texts
        let inserted = await inserter.texts
        XCTAssertEqual(inserted, [TextPipeline().run(texts.joined(separator: " ")).output.text])
        XCTAssertTrue(texts.allSatisfy { !$0.isEmpty })
        print("[long-file] audio=480s completedBeforeStop=\(completedPrefix) decodesAfterStop=\(counts.count - completedPrefix) stopToText=\(elapsed)")
    }

    private actor Probe {
        let transcriber: LocalTranscriber
        var sampleCounts: [Int] = []
        var texts: [String] = []
        var completed: Int { texts.count }
        init(transcriber: LocalTranscriber) { self.transcriber = transcriber }
        func recognize(_ samples: [Float]) async throws -> ASRResult {
            sampleCounts.append(samples.count)
            let result = try await transcriber.transcribe(samples: samples)
            texts.append(result.text)
            return result
        }
    }

    private actor Capture: AudioCapturing {
        let url: URL
        let segment: [Float]
        var sink: (@Sendable ([Float]) -> Void)?
        init(url: URL, segment: [Float]) { self.url = url; self.segment = segment }
        func setSegmentSink(_ sink: (@Sendable ([Float]) -> Void)?) { self.sink = sink }
        func startRecording() async throws -> URL {
            for _ in 0..<23 { sink?(segment) }
            return url
        }
        func stopRecording() async throws -> (url: URL, duration: TimeInterval) { (url, 480) }
        func freezeRecording() async throws -> CapturedRecording {
            CapturedRecording(url: url, duration: 480, samples: nil, consumedSampleCount: 23 * segment.count)
        }
        func abortRecording() async {}
    }
}
