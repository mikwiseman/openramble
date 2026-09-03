import XCTest
@testable import DictationCore

final class MeetingUtteranceAssemblerTests: XCTestCase {
    private func segment(
        _ channel: MeetingChannel, _ start: TimeInterval, _ end: TimeInterval, _ text: String, failed: Bool = false
    ) -> MeetingUtteranceAssembler.Segment {
        .init(channel: channel, start: start, end: end, text: text, isFailed: failed)
    }

    func testSameChannelSegmentsWithinTheGapMergeIntoOneParagraph() {
        var assembler = MeetingUtteranceAssembler()
        XCTAssertEqual(assembler.append(segment(.microphone, 0, 4, "Right, can everyone")), [])
        XCTAssertEqual(assembler.append(segment(.microphone, 4.5, 6, "hear me?")), [])
        let closed = assembler.flush()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].text, "Right, can everyone hear me?")
        XCTAssertEqual(closed[0].start, 0)
        XCTAssertEqual(closed[0].end, 6)
        XCTAssertEqual(closed[0].channel, .microphone)
    }

    func testTheOtherSideSpeakingClosesTheParagraph() {
        var assembler = MeetingUtteranceAssembler()
        _ = assembler.append(segment(.microphone, 0, 4, "Can everyone hear me?"))
        let closed = assembler.append(segment(.system, 4.2, 6, "Yes, loud and clear."))
        XCTAssertEqual(closed.map(\.text), ["Can everyone hear me?"])
        XCTAssertEqual(assembler.flush().map(\.channel), [.system])
    }

    func testAPauseLongerThanTheGapClosesTheParagraph() {
        var assembler = MeetingUtteranceAssembler(parameters: .init(gap: 1.2))
        _ = assembler.append(segment(.microphone, 0, 4, "One thought."))
        XCTAssertEqual(assembler.append(segment(.microphone, 5.1, 7, "Another")).map(\.text), [])
        XCTAssertEqual(assembler.append(segment(.microphone, 8.5, 9, "later thought")).map(\.text), ["One thought. Another"])
    }

    func testASentenceEndClosesOnlyOncePastTheSoftLength() {
        var assembler = MeetingUtteranceAssembler(parameters: .init(gap: 5, softDuration: 12, hardDuration: 40))
        _ = assembler.append(segment(.microphone, 0, 5, "Short so far."))
        XCTAssertEqual(assembler.append(segment(.microphone, 5, 10, "Still merging.")), [], "a full stop at five seconds is not a paragraph")
        _ = assembler.append(segment(.microphone, 10, 13, "Now past twelve."))
        XCTAssertEqual(assembler.append(segment(.microphone, 13, 15, "New one")).map(\.text), ["Short so far. Still merging. Now past twelve."])
    }

    func testTheHardLengthClosesWhateverTheText() {
        var assembler = MeetingUtteranceAssembler(parameters: .init(gap: 5, softDuration: 12, hardDuration: 40))
        _ = assembler.append(segment(.microphone, 0, 20, "no punctuation here"))
        _ = assembler.append(segment(.microphone, 20, 41, "and none here either"))
        XCTAssertEqual(assembler.append(segment(.microphone, 41, 45, "next")).count, 1)
    }

    func testAFailedSegmentIsItsOwnClosedParagraphAndMergesWithNothing() {
        var assembler = MeetingUtteranceAssembler()
        _ = assembler.append(segment(.microphone, 0, 4, "Before."))
        let closed = assembler.append(segment(.microphone, 4, 8, "", failed: true))
        XCTAssertEqual(closed.count, 2)
        XCTAssertEqual(closed[0].text, "Before.")
        XCTAssertTrue(closed[1].isFailed)
        XCTAssertEqual(closed[1].start, 4)
        XCTAssertEqual(assembler.append(segment(.microphone, 8, 10, "After.")), [], "the next one opens fresh")
        XCTAssertEqual(assembler.flush().map(\.text), ["After."])
    }

    func testSilenceDecodedAsNothingNeitherOpensNorCloses() {
        var assembler = MeetingUtteranceAssembler()
        XCTAssertEqual(assembler.append(segment(.microphone, 0, 3, "   ")), [])
        _ = assembler.append(segment(.microphone, 3, 5, "Hello"))
        XCTAssertEqual(assembler.append(segment(.microphone, 5, 6, "")), [])
        XCTAssertEqual(assembler.flush().map(\.text), ["Hello"])
    }

    func testSentenceEndingsAllowAClosingQuote() {
        XCTAssertTrue(MeetingUtteranceAssembler.endsSentence("Done."))
        XCTAssertTrue(MeetingUtteranceAssembler.endsSentence("Really?\""))
        XCTAssertTrue(MeetingUtteranceAssembler.endsSentence("Wait…"))
        XCTAssertFalse(MeetingUtteranceAssembler.endsSentence("and then"))
        XCTAssertFalse(MeetingUtteranceAssembler.endsSentence(""))
    }
}
