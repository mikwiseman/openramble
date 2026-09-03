import XCTest
@testable import DictationCore

/// `meta.json` and `transcript.json` have to read back what was written, and
/// — the part that has bitten this project before — read back older files
/// after fields are added.
final class MeetingRecordingCodableTests: XCTestCase {
    private func sample() -> MeetingRecordingMetadata {
        MeetingRecordingMetadata(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
            startedAt: Date(timeIntervalSince1970: 1_756_900_000),
            duration: 1234.5,
            title: "Weekly sync",
            microphoneDeviceName: "MacBook Pro Microphone",
            systemAudio: SystemAudioSummary(
                wasRequested: true,
                everDeliveredBuffers: true,
                everDeliveredAudio: true,
                outputTransport: "built-in"
            ),
            pauses: [MeetingInterval(start: 10, end: 20)],
            gaps: [MeetingGap(channel: .system, start: 30, end: 31, reason: .systemAudioRouteChange)],
            endReason: .stoppedByUser,
            transcriptionState: .complete
        )
    }

    func testMetadataRoundTrips() throws {
        let original = sample()
        let data = try MeetingRecordingCoding.encoder().encode(original)
        let decoded = try MeetingRecordingCoding.decoder().decode(MeetingRecordingMetadata.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDatesAreWrittenAsISO8601ForAPersonToRead() throws {
        let data = try MeetingRecordingCoding.encoder().encode(sample())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"startedAt\" : \"2025-09-03T11:46:40Z\""), text)
    }

    func testAMinimalFileFromAnEarlierVersionStillLoads() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startedAt":"2025-09-03T11:46:40Z"}
        """
        let decoded = try MeetingRecordingCoding.decoder()
            .decode(MeetingRecordingMetadata.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.duration, 0)
        XCTAssertNil(decoded.title)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertEqual(decoded.channelLayout, [.microphone, .system])
        XCTAssertFalse(decoded.systemAudio.wasRequested)
        XCTAssertEqual(decoded.pauses, [])
        XCTAssertEqual(decoded.gaps, [])
        XCTAssertNil(decoded.endReason)
        XCTAssertEqual(decoded.transcriptionState, .none)
        XCTAssertFalse(decoded.isMeeting)
    }

    func testAnUnknownFieldFromALaterVersionIsIgnored() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startedAt":"2025-09-03T11:46:40Z","futureField":42}
        """
        XCTAssertNoThrow(
            try MeetingRecordingCoding.decoder().decode(MeetingRecordingMetadata.self, from: Data(json.utf8))
        )
    }

    func testTranscriptRoundTripsIncludingThePerChannelResumptionPoint() throws {
        let original = MeetingTranscript(
            utterances: [
                MeetingUtterance(channel: .microphone, start: 0.5, end: 4.2, text: "Right, can everyone hear me?"),
                MeetingUtterance(channel: .system, start: 4.9, end: 6.0, text: "", isFailed: true),
            ],
            decodedFrames: [.microphone: 67_200, .system: 96_000]
        )
        let data = try MeetingRecordingCoding.encoder().encode(original)
        let decoded = try MeetingRecordingCoding.decoder().decode(MeetingTranscript.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testAnEmptyTranscriptFileLoadsAsEmpty() throws {
        let decoded = try MeetingRecordingCoding.decoder().decode(MeetingTranscript.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.utterances, [])
        XCTAssertEqual(decoded.decodedFrames, [:])
    }
}
