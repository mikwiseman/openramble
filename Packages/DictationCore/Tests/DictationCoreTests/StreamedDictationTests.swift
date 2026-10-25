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
            pipeline: { _ in TextPipeline() }
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

    /// Word timings survive the stream: each piece's words move onto the
    /// take's clock, so a long pause at the end of the first piece still
    /// becomes a paragraph in a prose app.
    func testWordTimingsAcrossPiecesMarkAParagraph() async {
        let samples = [Float](repeating: 0.5, count: 30 * 16_000)
        let capture = StreamingCapture(samples: samples, segments: [8 * 16_000, 8 * 16_000, 8 * 16_000])
        let inserter = FakeInserter()
        let pieces: [ASRResult] = [
            ASRResult(text: "First piece.", words: [
                .init(text: "First", start: 0.0, end: 0.4), .init(text: "piece.", start: 0.4, end: 0.9),
            ], audioDuration: 8, processingDuration: 0.01),
            ASRResult(text: "Second piece.", words: [
                .init(text: "Second", start: 0.0, end: 7.0), .init(text: "piece.", start: 7.0, end: 7.9),
            ], audioDuration: 8, processingDuration: 0.01),
            ASRResult(text: "Third piece.", words: [
                .init(text: "Third", start: 0.0, end: 7.0), .init(text: "piece.", start: 7.0, end: 7.9),
            ], audioDuration: 8, processingDuration: 0.01),
            ASRResult(text: "And the tail.", words: [
                .init(text: "And", start: 0.0, end: 0.2), .init(text: "the", start: 0.2, end: 0.4),
                .init(text: "tail.", start: 0.4, end: 0.8),
            ], audioDuration: 6, processingDuration: 0.01),
        ]
        let calls = UncheckedBox(0)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "", audioDuration: 0, processingDuration: 0) },
            transcribeSamples: { _ in
                // One decode runs at a time, so the count needs no lock.
                let index = calls.value
                calls.value += 1
                return pieces[min(index, pieces.count - 1)]
            },
            readSamples: { _ in await capture.readSamples() },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            pipeline: { _ in TextPipeline(mode: .prose) }
        )

        await run(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["First piece.\n\nSecond piece. Third piece. And the tail."])
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

    /// `engine` stays the tail — what the person waited for once the key was
    /// up — and `engineTotal` adds the pieces recognized while they spoke. A
    /// piece that paged the model back in from swap used to vanish from the
    /// log, leaving a 3.7-second take beside a quarter-second engine.
    func testTheEngineTotalCountsThePiecesRecognizedWhileSpeaking() async throws {
        let samples = [Float](repeating: 0.5, count: 30 * 16_000)
        let capture = StreamingCapture(samples: samples, segments: [8 * 16_000, 8 * 16_000, 8 * 16_000])
        let calls = UncheckedBox(0)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "", audioDuration: 0, processingDuration: 0) },
            transcribeSamples: { samples in
                let index = calls.value
                calls.value += 1
                // The first piece paid for the page-in; the tail did not.
                let seconds = [3.0, 0.2, 0.2, 0.25][min(index, 3)]
                return ASRResult(text: "piece", audioDuration: Double(samples.count) / 16_000,
                                 processingDuration: seconds)
            },
            readSamples: { _ in await capture.readSamples() },
            inserter: FakeInserter(),
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            pipeline: { _ in TextPipeline() }
        )
        var report: DictationSpeedReport?
        controller.onSpeed = { report = $0 }

        await run(controller)

        let phases = try XCTUnwrap(report?.phases)
        XCTAssertEqual(phases.streamedSegments, 3)
        XCTAssertEqual(try XCTUnwrap(phases.engineProcessing) / .seconds(1), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(phases.engineProcessingTotal) / .seconds(1), 3.65, accuracy: 0.0001)
    }

    func testATakeWithNoCutsReportsTheSameEngineTimeTwice() async throws {
        let samples = [Float](repeating: 0.5, count: 5 * 16_000)
        let controller = makeController(capture: StreamingCapture(samples: samples, segments: []),
                                        inserter: FakeInserter()) { _ in "one whole take." }
        var report: DictationSpeedReport?
        controller.onSpeed = { report = $0 }

        await run(controller)

        let phases = try XCTUnwrap(report?.phases)
        XCTAssertEqual(phases.engineProcessingTotal, phases.engineProcessing)
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

    /// A take short enough to need no cut is the ordinary path, not a
    /// fallback. It used to be journaled as `noSegments` on 234 of 273 takes in
    /// a week, which buried the one fallback worth reading: a failed segment.
    func testAWholeTakeWithNoSegmentsReportsNoFallback() async {
        let samples = [Float](repeating: 0.5, count: 5 * 16_000)
        let capture = StreamingCapture(samples: samples, segments: [])
        let inserter = FakeInserter()
        let controller = makeController(capture: capture, inserter: inserter) { _ in "one whole take." }
        var fallbackReasons: [DictationFallbackReason] = []
        controller.onRecognitionFallback = { reason, _ in fallbackReasons.append(reason) }

        await run(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.first, "One whole take.")
        XCTAssertEqual(fallbackReasons, [])
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
        var fallbackReasons: [DictationFallbackReason] = []
        controller.onRecognitionFallback = { reason, error in
            fallbackReasons.append(reason)
            guard case let .inferenceFailed(_, code) = error as? ASREngineError else {
                return XCTFail("the original stream error must survive the successful fallback")
            }
            XCTAssertEqual(code, -7)
        }

        await run(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.first, "Complete recording.")
        XCTAssertEqual(fallbackReasons, [.segmentFailed])
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
