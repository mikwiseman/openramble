import AVFoundation
import DictationAudio
import XCTest

/// What leaves the Mac has to be small, centered, and complete.
final class MeetingAudioExporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "meeting-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Five seconds of a tone on the left and silence on the right, sealed —
    /// a recording as the app leaves it.
    private func writeRecording(seconds: Int = 5) throws -> URL {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        let frames = seconds * 16_000
        let tone = (0..<frames).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        try writer.append(microphone: tone, system: [Float](repeating: 0, count: frames))
        try writer.finish()
        return directory.appending(path: "audio.wav")
    }

    func testAnExportIsCenteredTheSameLengthAndFarSmaller() throws {
        let source = try writeRecording()
        let destination = directory.appending(path: "export.m4a")
        var lastProgress: Double = 0
        try MeetingAudioExporter.export(from: source, to: destination, progress: { lastProgress = $0 })

        let exported = try AVAudioFile(forReading: destination)
        XCTAssertEqual(exported.processingFormat.channelCount, 1, "speech should play in both ears")
        XCTAssertEqual(
            Double(exported.length) / exported.processingFormat.sampleRate,
            5,
            accuracy: 0.2,
            "the whole recording, not a truncated one"
        )
        let sourceBytes = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        let exportedBytes = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int ?? 0
        XCTAssertLessThan(exportedBytes * 4, sourceBytes, "AAC at 32 kbps is a fraction of 16 kHz stereo PCM")
        XCTAssertEqual(lastProgress, 1)
    }

    func testArchiveKeepsBothChannelsAndShrinksTheCompletedRecording() throws {
        let source = try writeRecording(seconds: 8)
        let destination = directory.appending(path: "audio.m4a.incomplete")

        try MeetingAudioExporter.archive(from: source, to: destination)

        let archived = try AVAudioFile(forReading: destination)
        XCTAssertEqual(archived.processingFormat.channelCount, 2)
        XCTAssertEqual(
            Double(archived.length) / archived.processingFormat.sampleRate,
            8,
            accuracy: 0.2
        )
        let sourceBytes = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        let archivedBytes = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int ?? 0
        XCTAssertLessThan(archivedBytes * 3, sourceBytes, "the completed archive should not retain raw PCM size")
    }

    func testEitherSourceAndBothTogetherAreAudibleInTheExport() throws {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        let tone = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let silence = [Float](repeating: 0, count: tone.count)
        try writer.append(microphone: tone, system: silence)
        try writer.append(microphone: silence, system: tone)
        try writer.append(microphone: tone, system: tone)
        try writer.finish()
        let destination = directory.appending(path: "both.m4a")
        try MeetingAudioExporter.export(from: writer.audioURL, to: destination)

        let output = try AVAudioFile(forReading: destination)
        XCTAssertEqual(output.processingFormat.channelCount, 1)
        for second in 0..<3 {
            // Away from AAC priming and the transitions between speakers.
            output.framePosition = AVAudioFramePosition(second * 16_000 + 4_000)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 4_000))
            try output.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            let energy = (0..<Int(buffer.frameLength)).reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
            XCTAssertGreaterThan(sqrt(energy / Float(buffer.frameLength)), 0.1, "source missing at second \(second)")
        }
        // Exporting must not change the source tracks the recognizer reads.
        let original = try AVAudioFile(forReading: writer.audioURL)
        XCTAssertEqual(original.processingFormat.channelCount, 2)
    }

    /// A half-written export that plays for ten minutes of a two-hour
    /// meeting is worse than no file at all.
    func testACancelledExportLeavesNothingBehind() throws {
        let source = try writeRecording(seconds: 30)
        let destination = directory.appending(path: "cancelled.m4a")
        var calls = 0
        XCTAssertThrowsError(
            try MeetingAudioExporter.export(
                from: source,
                to: destination,
                isCancelled: {
                    calls += 1
                    return calls > 2
                }
            )
        ) { error in
            XCTAssertEqual(error as? MeetingAudioExporter.Failure, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAMissingRecordingIsReportedNotSwallowed() {
        XCTAssertThrowsError(
            try MeetingAudioExporter.export(
                from: directory.appending(path: "nothing.wav"),
                to: directory.appending(path: "out.m4a")
            )
        ) { error in
            guard case .unreadable = error as? MeetingAudioExporter.Failure else {
                return XCTFail("expected an unreadable failure, got \(error)")
            }
        }
    }
}

extension MeetingAudioExporter.Failure: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}
