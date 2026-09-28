import XCTest
@testable import DictationCore

/// A take recognized in pieces while it is still being spoken.
///
/// The unit tests around `SpeechSegmenter` and `StreamedSegmentRecognizer` pin
/// the parts. These pin the thing that actually ships: the controller taking
/// what the stream produced, adding the tail nobody has recognized yet, and
/// inserting one sentence rather than a pile of fragments.
@MainActor
final class StreamedDictationTests: XCTestCase {
    /// A capture that hands over segments the way the microphone does, and then
    /// reports how much of the take left in them.
    private actor StreamingCapture: AudioCapturing {
        private let file = URL(fileURLWithPath: "/tmp/streamed-take.wav")
        private let samples: [Float]
        private let fileBacked: Bool
        /// Sample counts to ship as segments before the key comes up.
        private let segments: [Int]
        private var sink: (@Sendable ([Float]) -> Void)?
        private(set) var consumed = 0

        init(samples: [Float], segments: [Int], fileBacked: Bool = false) {
            self.samples = samples
            self.segments = segments
            self.fileBacked = fileBacked
        }

        func setSegmentSink(_ sink: (@Sendable ([Float]) -> Void)?) { self.sink = sink }

        func startRecording() async throws -> URL {
            // Everything the segmenter would have found, handed over the way the
            // capture's queue hands it over: in order, while recording runs.
            var offset = 0
            for count in segments {
                guard offset + count <= samples.count else { break }
                sink?(Array(samples[offset..<(offset + count)]))
                offset += count
            }
            consumed = offset
            return file
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            (file, Double(samples.count) / 16_000)
        }

        func takeBufferedSamples() async -> [Float]? { samples }

        func freezeRecording() async throws -> CapturedRecording {
            CapturedRecording(
                url: file,
                duration: Double(samples.count) / 16_000,
                samples: fileBacked ? nil : samples,
                consumedSampleCount: consumed
            )
        }

        func abortRecording() async {}

        func readSamples() -> [Float] { samples }
    }

    private func makeController(
        capture: StreamingCapture,
        inserter: FakeInserter,
        onSamples: @escaping @Sendable ([Float]) -> String
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in
                XCTFail("a streamed take must not fall back to reopening the WAV")
                return ASRResult(text: "", audioDuration: 0, processingDuration: 0)
            },
            transcribeSamples: { samples in
                ASRResult(
                    text: onSamples(samples),
                    audioDuration: Double(samples.count) / 16_000,
                    processingDuration: 0.01
                )
            },
            readSamples: { _ in await capture.readSamples() },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            pipeline: { TextPipeline() }
        )
    }

    private func run(_ controller: DictationController) async {
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle(40)
    }

    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testTheStreamedPiecesAndTheTailBecomeOneSentence() async {
        // Thirty seconds, cut into three pieces of eight, leaving six for the
        // tail — the shape of an ordinary long dictation.
        let samples = [Float](repeating: 0.5, count: 30 * 16_000)
        let capture = StreamingCapture(
            samples: samples,
            segments: [8 * 16_000, 8 * 16_000, 8 * 16_000]
        )
        let inserter = FakeInserter()
        let controller = makeController(capture: capture, inserter: inserter) { chunk in
            chunk.count == 6 * 16_000 ? "and the tail." : "A piece"
        }

        await run(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(
            inserted.first,
            "A piece A piece A piece and the tail.",
            "the pieces recognized during the take must lead, in order, with the tail last"
        )
    }

    func testATailTooShortToTrustIsRecognizedWithTheSegmentBeforeIt() async {
        // The key comes up half a second after a cut. On its own that tail is
        // in the range where this decoder is non-monotonic, so the segment
        // before it must come back and the two go through together.
        let samples = [Float](repeating: 0.5, count: 20 * 16_000)
        let capture = StreamingCapture(
            samples: samples,
            segments: [8 * 16_000, 11 * 16_000 + 8_000]
        )
        let inserter = FakeInserter()
        let controller = makeController(capture: capture, inserter: inserter) { chunk in
            // The re-decode covers the last segment plus the stub tail.
            chunk.count >= 11 * 16_000 ? "second and tail together." : "first"
        }

        await run(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(
            inserted.first,
            "First second and tail together.",   // the polisher capitalizes, as it always has
            "a stub tail must never be handed to the engine on its own"
        )
    }

    func testATakeWithNoCutsBehavesExactlyAsItAlwaysDid() async {
        let samples = [Float](repeating: 0.5, count: 5 * 16_000)
        let capture = StreamingCapture(samples: samples, segments: [])
        let inserter = FakeInserter()
        let controller = makeController(capture: capture, inserter: inserter) { chunk in
            XCTAssertEqual(chunk.count, samples.count, "the whole take goes in one decode")
            return "one whole take."
        }

        await run(controller)
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.first, "One whole take.")
    }

    func testEightMinuteFileBackedTakeReusesEveryStreamedPiece() async {
        let samples = [Float](repeating: 0.5, count: 480 * 16_000)
        let capture = StreamingCapture(samples: samples,
            segments: Array(repeating: 20 * 16_000, count: 23), fileBacked: true)
        let inserter = FakeInserter()
        let controller = makeController(capture: capture, inserter: inserter) { chunk in
            XCTAssertEqual(chunk.count, 20 * 16_000, "only the last 20 seconds need recognition at stop")
            return "piece"
        }

        await run(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.first?.lowercased().split(separator: " ").count, 24,
                       "all 23 precomputed pieces and the tail must survive the five-minute memory boundary")
    }

    func testFileBackedShortTailIsJoinedToThePreviousSegment() async {
        let samples = [Float](repeating: 0.5, count: 360 * 16_000)
        let capture = StreamingCapture(samples: samples,
            segments: [340 * 16_000, 19 * 16_000], fileBacked: true)
        let inserter = FakeInserter()
        let controller = makeController(capture: capture, inserter: inserter) { chunk in
            switch chunk.count {
            case 340 * 16_000: return "first"
            case 19 * 16_000: return "discard this version"
            case 20 * 16_000: return "second and tail together."
            default: XCTFail("unexpected decode length: \(chunk.count)"); return "wrong"
            }
        }

        await run(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.first, "First second and tail together.")
    }

    func testFailedStreamStillRecognizesTheCompleteFile() async {
        let capture = StreamingCapture(samples: [Float](repeating: 0.5, count: 360 * 16_000),
                                       segments: [20 * 16_000], fileBacked: true)
        let inserter = FakeInserter()
        let controller = DictationController(capture: capture,
            transcribe: { _ in ASRResult(text: "complete recording.", audioDuration: 360, processingDuration: 1) },
            transcribeSamples: { _ in throw ASREngineError.inferenceFailed("failed segment", code: -7) },
            readSamples: { _ in XCTFail("failed prefix cannot be reused"); return [] },
            inserter: inserter, overlay: FakeOverlay(), sounds: FakeSounds())

        await run(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.first, "Complete recording.")
    }

    func testTruncatedFileDoesNotPublishAPartialTranscript() async {
        let samples = [Float](repeating: 0.5, count: 360 * 16_000)
        let capture = StreamingCapture(samples: samples, segments: [20 * 16_000], fileBacked: true)
        let inserter = FakeInserter()
        let controller = DictationController(capture: capture,
            transcribe: { _ in XCTFail("must not hide an incomplete file"); throw ASREngineError.cancelled },
            transcribeSamples: { _ in ASRResult(text: "prefix", audioDuration: 20, processingDuration: 0.01) },
            readSamples: { _ in Array(samples.prefix(25 * 16_000)) },
            inserter: inserter, overlay: FakeOverlay(), sounds: FakeSounds())
        var failure: ASREngineError?
        controller.onRecognitionFailure = { failure = $0 as? ASREngineError }

        await run(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertTrue(inserted.isEmpty)
        guard case .unsupportedAudioFormat = failure else { return XCTFail("missing technical failure") }
        XCTAssertEqual(controller.state, .idle)
    }
}
