import XCTest
@testable import DictationAudio

final class PeakFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "peakfile-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBucketsRoundTripPerChannel() throws {
        let url = directory.appending(path: "peaks.bin")
        let file = PeakFile(url: url, channelCount: 2)
        try file.open()
        try file.append([0.0, 1.0])
        try file.append([0.5, 0.25])
        try file.close()

        let contents = try PeakFile.read(url: url)
        XCTAssertEqual(contents.framesPerBucket, PeakFile.defaultFramesPerBucket)
        XCTAssertEqual(contents.channels.count, 2)
        XCTAssertEqual(contents.channels[0], [0, Float(128) / 255])
        XCTAssertEqual(contents.channels[1], [1, Float(64) / 255])
    }

    func testAFileThatNeverClosedStillReadsEveryBucketThatReachedDisk() throws {
        let url = directory.appending(path: "peaks.bin")
        let file = PeakFile(url: url, channelCount: 2)
        try file.open()
        try file.append([0.2, 0.4])
        try file.append([0.6, 0.8])
        file.abandon()

        let contents = try PeakFile.read(url: url)
        XCTAssertEqual(contents.channels[0].count, 2)
        XCTAssertEqual(contents.channels[1].count, 2)
    }

    func testValuesOutsideZeroToOneAreClamped() throws {
        let url = directory.appending(path: "peaks.bin")
        let file = PeakFile(url: url, channelCount: 2)
        try file.open()
        try file.append([-3, 7])
        try file.close()
        XCTAssertEqual(try PeakFile.read(url: url).channels.map(\.first), [0, 1])
    }

    func testTheWrongNumberOfPeaksIsRefused() throws {
        let file = PeakFile(url: directory.appending(path: "peaks.bin"), channelCount: 2)
        try file.open()
        XCTAssertThrowsError(try file.append([0.5]))
        try file.close()
    }

    func testAForeignFileIsRejectedRatherThanMisread() throws {
        let url = directory.appending(path: "not-peaks.bin")
        try Data("hello world, this is not a peak file".utf8).write(to: url)
        XCTAssertThrowsError(try PeakFile.read(url: url))
    }
}
