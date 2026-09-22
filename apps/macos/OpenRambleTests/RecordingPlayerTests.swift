import AVFoundation
import DictationAudio
import XCTest

/// Render the production playback graph into stereo PCM: checking pan or
/// channel counts alone would still pass while one ear stayed silent.
@MainActor
final class RecordingPlayerTests: XCTestCase {
    private var directory: URL!
    private var engine: AVAudioEngine!
    private var player: RecordingPlayer!
    private let rate = 16_000

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "recording-player-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engine = AVAudioEngine()
        player = RecordingPlayer(engine: engine)
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2))
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 1_024)
    }

    override func tearDown() async throws {
        player.unload()
        player = nil
        engine = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Mic only, system only, then both. The same loud signal on both
    /// sources also catches a mix that adds them without clipping headroom.
    private func recording() throws -> URL {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        let tone = (0..<rate).map { Float(sin(Double($0) * 0.05)) * 0.9 }
        let silence = [Float](repeating: 0, count: rate)
        try writer.append(microphone: tone, system: silence)
        try writer.append(microphone: silence, system: tone)
        try writer.append(microphone: tone, system: tone)
        try writer.finish()
        return writer.audioURL
    }

    private func render(seconds: Double) throws -> [[Float]] {
        let frames = Int(seconds * Double(rate))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024))
        var result = [[Float](), [Float]()]
        var retries = 0
        while result[0].count < frames {
            let count = AVAudioFrameCount(min(1_024, frames - result[0].count))
            let status = try engine.renderOffline(count, to: buffer)
            if status == .cannotDoInCurrentContext, retries < 100 {
                retries += 1
                continue
            }
            XCTAssertEqual(status, .success)
            guard status == .success, buffer.frameLength > 0 else { break }
            for channel in 0..<2 {
                result[channel] += UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
            }
        }
        XCTAssertEqual(result[0].count, frames)
        return result
    }

    private func assertCentered(_ samples: [[Float]], file: StaticString = #filePath, line: UInt = #line) {
        let peak = samples[0].map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.2, "speech must be audible", file: file, line: line)
        XCTAssertLessThan(peak, 1, "simultaneous voices must not clip", file: file, line: line)
        let difference = zip(samples[0], samples[1]).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(difference, 0.0001, "both ears must hear the same mix", file: file, line: line)
    }

    func testMicrophoneSystemAndBothPlayInBothEarsWithoutClipping() throws {
        player.load(id: UUID(), url: try recording())
        XCTAssertEqual(player.duration, 3, accuracy: 0.001)
        player.toggle()
        let audio = try render(seconds: 3)
        for second in 0..<3 {
            let range = (second * rate + 4_000)..<(second * rate + 12_000)
            assertCentered(audio.map { Array($0[range]) })
        }
    }

    func testPauseResumeAndSeekKeepPositionAndCenteredAudio() throws {
        player.load(id: UUID(), url: try recording())
        player.toggle()
        _ = try render(seconds: 0.25)
        player.pause()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(engine.isRunning, "a paused player should stop rendering")
        XCTAssertEqual(player.currentTime, 0.25, accuracy: 0.07)

        player.toggle()
        assertCentered(try render(seconds: 0.25))
        player.pause()
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.07)

        player.seek(to: 1.25)
        XCTAssertEqual(player.currentTime, 1.25, accuracy: 0.001)
        XCTAssertFalse(player.isPlaying)
        player.toggle()
        assertCentered(try render(seconds: 0.25))
        player.pause()
        XCTAssertEqual(player.currentTime, 1.5, accuracy: 0.07)
    }

    func testSeekingWhilePlayingAndPlayingAgainAtTheEnd() throws {
        player.load(id: UUID(), url: try recording())
        player.toggle()
        _ = try render(seconds: 0.1)
        player.seek(to: 2.25)
        XCTAssertTrue(player.isPlaying)
        assertCentered(try render(seconds: 0.25))
        player.seek(to: 50)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 3)
        player.toggle()
        XCTAssertTrue(player.isPlaying)
        assertCentered(try render(seconds: 0.25))
        player.pause()
        XCTAssertEqual(player.currentTime, 0.25, accuracy: 0.07)
    }

    func testOldCompletionCannotFinishANewSelection() async throws {
        let url = try recording()
        player.load(id: UUID(), url: url)
        player.toggle()
        _ = try render(seconds: 0.1)
        let id = UUID()
        player.load(id: id, url: url)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(player.loadedID, id)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertFalse(player.isPlaying)
        player.seek(to: 1)
        player.load(id: id, url: url)
        XCTAssertEqual(player.currentTime, 1, "re-rendering a view must not restart its recording")
    }

    func testFinishingStopsThePlayerAndPlayRestartsFromTheBeginning() async throws {
        // dataPlayedBack follows the output device's clock. Offline renders
        // deliberately have no such clock, so verify completion on the real
        // output, muted to keep the suite silent.
        engine.disableManualRenderingMode()
        guard engine.outputNode.outputFormat(forBus: 0).sampleRate > 0 else {
            throw XCTSkip("No audio output device")
        }
        player.load(id: UUID(), url: try recording())
        engine.mainMixerNode.outputVolume = 0
        player.seek(to: 2.75)
        player.toggle()
        let deadline = ContinuousClock.now + .seconds(2)
        while player.isPlaying, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(player.currentTime, 3)
        player.toggle()
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
        player.pause()
    }

    func testOutputChangeResumesAndAPausedPlayerStaysPaused() async throws {
        player.load(id: UUID(), url: try recording())
        player.seek(to: 1.25)
        player.toggle()
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(engine.isRunning)
        assertCentered(try render(seconds: 0.25))
        player.pause()
        let pausedTime = player.currentTime
        // A device format change resets the graph, including scheduled audio.
        engine.stop()
        engine.reset()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(player.currentTime, pausedTime, accuracy: 0.001)
        player.toggle()
        assertCentered(try render(seconds: 0.25))
        player.pause()
        XCTAssertEqual(player.currentTime, pausedTime + 0.25, accuracy: 0.07)
    }

    func testMissingAudioIsReportedAndUnloadingClearsIt() {
        player.load(id: UUID(), url: directory.appending(path: "missing.wav"))
        XCTAssertTrue(player.failedToLoad)
        player.toggle()
        XCTAssertFalse(player.isPlaying)
        player.unload()
        XCTAssertFalse(player.failedToLoad)
        XCTAssertNil(player.loadedID)
    }

    func testMissingVideoKeepsTheLocalAudioFallback() throws {
        player.load(
            id: UUID(),
            url: try recording(),
            videoURL: directory.appending(path: "missing.mp4")
        )
        XCTAssertTrue(player.videoFailedToLoad)
        XCTAssertFalse(player.failedToLoad)
        XCTAssertEqual(player.duration, 3, accuracy: 0.001)

        player.toggle()
        assertCentered(try render(seconds: 0.25))
        player.pause()
    }
}
