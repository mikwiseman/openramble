import XCTest
@testable import DictationCore

/// One stereo timeline from two streams. Every test is about a property of the
/// output — monotonic, contiguous, silence where a channel had nothing — because
/// those are what the file format and the transcript rely on.
final class DualChannelAlignerTests: XCTestCase {
    private func constant(_ value: Float, _ count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    func testAVoiceNoteWritesSilenceOnTheSystemSideWithoutCountingAGap() throws {
        var aligner = DualChannelAligner(activeChannels: [.microphone], jitterFrames: 1_600)
        aligner.ingest(channel: .microphone, startFrame: 0, samples: constant(0.5, 3_200))

        let emission = try XCTUnwrap(aligner.drain())
        XCTAssertEqual(emission.startFrame, 0)
        XCTAssertEqual(emission.frameCount, 1_600, "emission lags the newest frame by the jitter window")
        XCTAssertEqual(emission.microphone, constant(0.5, 1_600))
        XCTAssertEqual(emission.system, constant(0, 1_600))
        XCTAssertEqual(aligner.gapFrames[.system, default: 0], 0, "an inactive channel is not missing")
        XCTAssertEqual(aligner.gapFrames[.microphone, default: 0], 0)
    }

    func testAGapIsSilenceFilledOnThatChannelOnlyAndCounted() throws {
        var aligner = DualChannelAligner(jitterFrames: 0)
        aligner.ingest(channel: .microphone, startFrame: 0, samples: constant(0.5, 3_200))
        aligner.ingest(channel: .system, startFrame: 0, samples: constant(-0.5, 1_600))

        let emission = try XCTUnwrap(aligner.flush())
        XCTAssertEqual(emission.microphone, constant(0.5, 3_200))
        XCTAssertEqual(Array(emission.system[0..<1_600]), constant(-0.5, 1_600))
        XCTAssertEqual(Array(emission.system[1_600..<3_200]), constant(0, 1_600))
        XCTAssertEqual(aligner.gapFrames[.system], 1_600)
        XCTAssertEqual(aligner.gapFrames[.microphone, default: 0], 0)
    }

    func testAChannelThatStartsLateIsSilenceFilledBeforeItsFirstBlock() throws {
        var aligner = DualChannelAligner(jitterFrames: 0)
        aligner.ingest(channel: .microphone, startFrame: 0, samples: constant(0.5, 2_000))
        aligner.ingest(channel: .system, startFrame: 1_000, samples: constant(-0.5, 1_000))

        let emission = try XCTUnwrap(aligner.flush())
        XCTAssertEqual(Array(emission.system[0..<1_000]), constant(0, 1_000))
        XCTAssertEqual(Array(emission.system[1_000..<2_000]), constant(-0.5, 1_000))
        XCTAssertEqual(aligner.gapFrames[.system], 1_000)
    }

    func testALateBlockIsTruncatedAtTheCursorAndTheDroppedFramesAreCounted() throws {
        var aligner = DualChannelAligner(jitterFrames: 0)
        aligner.ingest(channel: .microphone, startFrame: 0, samples: constant(0.1, 1_600))
        aligner.ingest(channel: .system, startFrame: 0, samples: constant(0.1, 1_600))
        XCTAssertEqual(aligner.flush()?.frameCount, 1_600)

        // 800 frames of this block are already in the past.
        aligner.ingest(channel: .microphone, startFrame: 800, samples: constant(0.9, 1_600))
        let emission = try XCTUnwrap(aligner.flush())
        XCTAssertEqual(emission.startFrame, 1_600, "the past is never rewritten")
        XCTAssertEqual(emission.frameCount, 800)
        XCTAssertEqual(emission.microphone, constant(0.9, 800))
        XCTAssertEqual(aligner.droppedLateFrames[.microphone], 800)
    }

    func testABlockEntirelyInThePastIsDroppedWhole() throws {
        var aligner = DualChannelAligner(jitterFrames: 0)
        aligner.ingest(channel: .microphone, startFrame: 0, samples: constant(0.1, 3_200))
        _ = aligner.flush()
        aligner.ingest(channel: .microphone, startFrame: 500, samples: constant(0.9, 1_000))
        XCTAssertNil(aligner.flush())
        XCTAssertEqual(aligner.droppedLateFrames[.microphone], 1_000)
    }

    func testADeadChannelNeverBlocksTheFile() throws {
        var aligner = DualChannelAligner(jitterFrames: 1_600)
        var totalEmitted = 0
        for block in 0..<10 {
            aligner.ingest(channel: .microphone, startFrame: block * 1_600, samples: constant(0.5, 1_600))
            // The system side delivered twice and then went quiet for good.
            if block < 2 {
                aligner.ingest(channel: .system, startFrame: block * 1_600, samples: constant(-0.5, 1_600))
            }
            if let emission = aligner.drain() { totalEmitted += emission.frameCount }
        }
        XCTAssertEqual(totalEmitted, 9 * 1_600, "the file kept growing on the live channel alone")
        XCTAssertEqual(aligner.gapFrames[.system], 7 * 1_600)
        XCTAssertEqual(aligner.gapFrames[.microphone, default: 0], 0)
    }

    func testEmissionsAreContiguousAndCoverEveryFrameExactlyOnce() throws {
        var aligner = DualChannelAligner(jitterFrames: 700)
        var expectedNext = 0
        var covered = 0
        // Irregular block sizes on both sides, the system side slightly ahead.
        let microphoneBlocks = [1_024, 512, 2_048, 300, 1_024, 1_024]
        let systemBlocks = [1_000, 1_000, 1_000, 1_000, 1_000, 1_000]
        var microphoneStart = 0
        var systemStart = 0
        for (m, s) in zip(microphoneBlocks, systemBlocks) {
            aligner.ingest(channel: .microphone, startFrame: microphoneStart, samples: constant(0.2, m))
            microphoneStart += m
            aligner.ingest(channel: .system, startFrame: systemStart, samples: constant(0.3, s))
            systemStart += s
            if let emission = aligner.drain() {
                XCTAssertEqual(emission.startFrame, expectedNext, "no gap and no overlap between emissions")
                expectedNext = emission.startFrame + emission.frameCount
                covered += emission.frameCount
            }
        }
        if let tail = aligner.flush() {
            XCTAssertEqual(tail.startFrame, expectedNext)
            covered += tail.frameCount
        }
        XCTAssertEqual(covered, max(microphoneStart, systemStart))
        XCTAssertEqual(aligner.emittedFrames, covered)
    }

    func testSamplesLandAtTheirFrameNotAtTheEndOfTheQueue() throws {
        var aligner = DualChannelAligner(jitterFrames: 0)
        aligner.ingest(channel: .microphone, startFrame: 0, samples: constant(0.5, 4_000))
        // A system block whose position says "frame 1000", whatever order it
        // arrived in.
        aligner.ingest(channel: .system, startFrame: 1_000, samples: [0.7, 0.8, 0.9])
        let emission = try XCTUnwrap(aligner.flush())
        XCTAssertEqual(emission.system[999], 0)
        XCTAssertEqual(emission.system[1_000], 0.7)
        XCTAssertEqual(emission.system[1_002], 0.9)
        XCTAssertEqual(emission.system[1_003], 0)
    }

    func testABlockSpanningTheEmissionBoundaryIsSplitNotDuplicated() throws {
        var aligner = DualChannelAligner(jitterFrames: 1_000)
        aligner.ingest(channel: .microphone, startFrame: 0, samples: (0..<3_000).map { Float($0) })
        let first = try XCTUnwrap(aligner.drain())
        XCTAssertEqual(first.frameCount, 2_000)
        XCTAssertEqual(first.microphone.last, 1_999)
        let rest = try XCTUnwrap(aligner.flush())
        XCTAssertEqual(rest.startFrame, 2_000)
        XCTAssertEqual(rest.microphone.first, 2_000)
        XCTAssertEqual(rest.microphone.last, 2_999)
        XCTAssertEqual(aligner.gapFrames[.microphone, default: 0], 0)
    }

    func testNothingToEmitReturnsNil() throws {
        var aligner = DualChannelAligner()
        XCTAssertNil(aligner.drain())
        XCTAssertNil(aligner.flush())
        aligner.ingest(channel: .microphone, startFrame: 0, samples: constant(0.5, 100))
        XCTAssertNil(aligner.drain(), "inside the jitter window nothing is certain yet")
        XCTAssertEqual(aligner.flush()?.frameCount, 100)
    }
}
