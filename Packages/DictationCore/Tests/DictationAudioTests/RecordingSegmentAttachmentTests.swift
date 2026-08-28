import DictationCore
import XCTest
@testable import DictationAudio

/// The piece between the microphone and the segmenter.
///
/// It is fed from the audio thread inside the sequenced lossless commit, so the
/// two things worth proving are that it hands back exactly the audio it was
/// given, in order, and that the count it reports at freeze is the truth — the
/// tail the controller decodes starts at that number, so a wrong one either
/// loses words or says them twice.
final class RecordingSegmentAttachmentTests: XCTestCase {
    /// A segmenter with a short segment floor, so a ten-second fixture can earn
    /// a cut. The shipped floor is far higher and is pinned by
    /// `SpeechSegmenterTests`; these tests are about the plumbing around it, not
    /// about the number.
    private var mechanism: SpeechSegmenter {
        SpeechSegmenter(
            parameters: .init(minimumPause: .milliseconds(700), minimumSegment: .seconds(4))
        )
    }

    /// Frames of the size the real tap delivers.
    private func feed(_ attachment: RecordingSegmentAttachment, _ level: Float, seconds: Double) {
        var remaining = Int(seconds * 16_000)
        while remaining > 0 {
            let count = min(2048, remaining)
            attachment.submit([Float](repeating: level, count: count))
            remaining -= count
        }
    }

    func testWithoutASinkNothingIsSegmentedAtAll() {
        let attachment = RecordingSegmentAttachment()
        feed(attachment, 0.5, seconds: 30)
        feed(attachment, 0, seconds: 2)
        XCTAssertEqual(
            attachment.drainConsumedSampleCount(), 0,
            "a capture nobody asked to segment must behave exactly as it did before"
        )
    }

    func testSegmentsCarryTheAudioTheyWereGivenAndTheCountMatches() {
        let collected = Collected()
        let attachment = RecordingSegmentAttachment(segmenter: mechanism)
        attachment.setSink { collected.append($0) }

        // Ten seconds of speech, then a pause long enough to earn a cut.
        feed(attachment, 0.5, seconds: 10)
        feed(attachment, 0, seconds: 1.5)
        // And more speech, which stays pending as the tail.
        feed(attachment, 0.5, seconds: 3)

        let consumed = attachment.drainConsumedSampleCount()
        let segments = collected.segments

        XCTAssertEqual(segments.count, 1, "one pause, one segment")
        XCTAssertEqual(
            segments.first?.count, consumed,
            "the reported count must be exactly what left in segments"
        )
        // Everything shipped came from the speech at the start, so it is that
        // level: proof the bytes are the ones handed in, not a reconstruction.
        XCTAssertEqual(segments.first?.first, 0.5)
    }

    func testTheReportedCountIsAConsistentPrefixOfTheTake() {
        let collected = Collected()
        let attachment = RecordingSegmentAttachment(segmenter: mechanism)
        attachment.setSink { collected.append($0) }

        for _ in 0..<3 {
            feed(attachment, 0.5, seconds: 8)
            feed(attachment, 0, seconds: 1.2)
        }

        let consumed = attachment.drainConsumedSampleCount()
        let total = collected.segments.reduce(0) { $0 + $1.count }
        XCTAssertEqual(
            consumed, total,
            "the tail begins where the segments end; anything else double-counts or drops audio"
        )
        XCTAssertGreaterThan(collected.segments.count, 1)
    }

    func testDrainingIsABarrierSoNothingArrivesAfterTheCount() {
        let collected = Collected()
        let attachment = RecordingSegmentAttachment(segmenter: mechanism)
        attachment.setSink { collected.append($0) }

        feed(attachment, 0.5, seconds: 10)
        feed(attachment, 0, seconds: 1.5)
        let consumed = attachment.drainConsumedSampleCount()
        let after = collected.segments.reduce(0) { $0 + $1.count }

        XCTAssertEqual(consumed, after,
                       "every submitted frame must be processed before the count is read")

        // And a frame that arrives late, after the take is over, is ignored
        // rather than appended behind the tail the controller already has.
        feed(attachment, 0.5, seconds: 10)
        feed(attachment, 0, seconds: 1.5)
        XCTAssertEqual(attachment.drainConsumedSampleCount(), consumed)
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Float]] = []

    func append(_ samples: [Float]) {
        lock.withLock { storage.append(samples) }
    }

    var segments: [[Float]] { lock.withLock { storage } }
}
