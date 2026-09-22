import AVFoundation
import CoreVideo
import XCTest

final class ScreenMovieWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "screen-movie-writer-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAlignedAudioAndVideoProduceOneH264AndOneAACTrack() async throws {
        let url = directory.appending(path: "video.mp4")
        let writer = try ScreenMovieWriter(url: url, width: 320, height: 180)
        let frame = try pixelBuffer(width: 320, height: 180)
        let oneSecond = [Float](repeating: 0.1, count: 16_000)

        XCTAssertTrue(writer.appendVideo(frame, at: CMTime(value: 0, timescale: 16_000)))
        XCTAssertTrue(writer.appendAudio(microphone: oneSecond, system: [], startFrame: 0))
        XCTAssertTrue(writer.appendVideo(frame, at: CMTime(value: 16_000, timescale: 16_000)))
        XCTAssertTrue(writer.appendAudio(microphone: oneSecond, system: [], startFrame: 16_000))
        try await writer.finish()

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        XCTAssertEqual(tracks.filter { $0.mediaType == .video }.count, 1)
        XCTAssertEqual(tracks.filter { $0.mediaType == .audio }.count, 1)

        let video = try XCTUnwrap(tracks.first { $0.mediaType == .video })
        let videoDescriptions = try await video.load(.formatDescriptions)
        let videoDescription = try XCTUnwrap(videoDescriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(videoDescription), kCMVideoCodecType_H264)

        let audio = try XCTUnwrap(tracks.first { $0.mediaType == .audio })
        let audioDescriptions = try await audio.load(.formatDescriptions)
        let audioDescription = try XCTUnwrap(audioDescriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioDescription), kAudioFormatMPEG4AAC)

        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.1)
    }

    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "ScreenMovieWriterTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 24, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
