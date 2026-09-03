import AVFoundation
import DictationCore
import XCTest
@testable import DictationAudio

/// A source that delivers what the test says, when the test says.
final class ScriptedAudioSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var onBlock: (@Sendable (MeetingAudioBlock) -> Void)?
    private var onFailure: (@Sendable (MeetingSourceFailure) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var deviceName: String? { "Scripted" }

    func start(
        onBlock: @escaping @Sendable (MeetingAudioBlock) -> Void,
        onFailure: @escaping @Sendable (MeetingSourceFailure) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        startCount += 1
        self.onBlock = onBlock
        self.onFailure = onFailure
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopCount += 1
        onBlock = nil
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onBlock != nil
    }

    func deliver(_ samples: [Float], hostNanoseconds: UInt64? = nil) {
        lock.lock()
        let block = onBlock
        lock.unlock()
        block?(MeetingAudioBlock(hostNanoseconds: hostNanoseconds, samples: samples))
    }

    func fail(_ failure: MeetingSourceFailure) {
        lock.lock()
        let handler = onFailure
        lock.unlock()
        handler?(failure)
    }
}

final class MeetingCaptureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "meeting-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func constant(_ value: Float, _ count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    private func readChannels(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let count = Int(buffer.frameLength)
        return (
            Array(UnsafeBufferPointer(start: data[0], count: count)),
            Array(UnsafeBufferPointer(start: data[1], count: count))
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("timed out waiting"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAVoiceNoteRecordsTheMicrophoneLeftAndSilenceRight() async throws {
        let microphone = ScriptedAudioSource()
        let capture = MeetingCapture(directory: directory, microphone: microphone, systemAudio: nil)
        try await capture.start()
        let started = await capture.state
        XCTAssertEqual(started, .recording)
        for _ in 0..<3 { microphone.deliver(constant(0.5, 1_600)) }
        let summary = try await capture.stop()

        XCTAssertEqual(summary.frameCount, 4_800)
        XCTAssertEqual(summary.duration, 0.3, accuracy: 0.0001)
        XCTAssertFalse(summary.systemAudio.wasRequested)
        XCTAssertEqual(summary.endReason, .stoppedByUser)
        XCTAssertEqual(summary.microphoneDeviceName, "Scripted")
        XCTAssertEqual(microphone.stopCount, 1)
        let ended = await capture.state
        XCTAssertEqual(ended, .stopped)

        let audio = try readChannels(await capture.audioURL)
        XCTAssertEqual(audio.left.count, 4_800)
        XCTAssertEqual(audio.left[100], 0.5, accuracy: 0.001)
        XCTAssertEqual(audio.right[100], 0, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "peaks.bin").path))
    }

    func testTwoSourcesLandOnTheirOwnChannels() async throws {
        let microphone = ScriptedAudioSource()
        let system = ScriptedAudioSource()
        let capture = MeetingCapture(directory: directory, microphone: microphone, systemAudio: system)
        try await capture.start()
        for _ in 0..<4 {
            microphone.deliver(constant(0.5, 800))
            system.deliver(constant(-0.5, 800))
        }
        let summary = try await capture.stop()

        XCTAssertEqual(summary.frameCount, 3_200)
        XCTAssertTrue(summary.systemAudio.wasRequested)
        XCTAssertTrue(summary.systemAudio.everDeliveredBuffers)
        XCTAssertTrue(summary.systemAudio.everDeliveredAudio)
        let audio = try readChannels(await capture.audioURL)
        XCTAssertEqual(audio.left[1_000], 0.5, accuracy: 0.001)
        XCTAssertEqual(audio.right[1_000], -0.5, accuracy: 0.001)
    }

    func testASilentSystemSideIsAliveButNotAudible() async throws {
        let microphone = ScriptedAudioSource()
        let system = ScriptedAudioSource()
        let capture = MeetingCapture(directory: directory, microphone: microphone, systemAudio: system)
        try await capture.start()
        microphone.deliver(constant(0.3, 1_600))
        system.deliver(constant(0, 1_600))
        let summary = try await capture.stop()
        XCTAssertTrue(summary.systemAudio.everDeliveredBuffers, "buffers arrived — the tap is alive")
        XCTAssertFalse(summary.systemAudio.everDeliveredAudio, "but nobody said anything")
        let health = await capture.health(of: .system)
        XCTAssertNotNil(health.lastBlockAt)
        XCTAssertNil(health.lastAudibleAt)
    }

    func testHostTimedBlocksFromTwoClocksStayAligned() async throws {
        let microphone = ScriptedAudioSource()
        let system = ScriptedAudioSource()
        let capture = MeetingCapture(directory: directory, microphone: microphone, systemAudio: system)
        try await capture.start()
        let anchor = UInt64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000)
        let blockNanoseconds: UInt64 = 100_000_000
        // The system side arrives 30 ms "late" by its own clock every block;
        // that is jitter, and the count must win over it.
        for i in 0..<5 {
            let at = anchor + UInt64(i) * blockNanoseconds
            microphone.deliver(constant(0.5, 1_600), hostNanoseconds: at)
            system.deliver(constant(-0.5, 1_600), hostNanoseconds: at + 30_000_000)
        }
        let summary = try await capture.stop()
        // The first block may land a few frames after zero (the anchor was
        // taken just before), so the file is 8 000 frames plus a little; the
        // system side's first block anchors 30 ms later than the microphone's
        // and stays there, which is the count winning over jitter.
        XCTAssertGreaterThanOrEqual(summary.frameCount, 8_000)
        XCTAssertLessThan(summary.frameCount, 8_000 + 1_600)
        let audio = try readChannels(await capture.audioURL)
        XCTAssertEqual(audio.left[4_000], 0.5, accuracy: 0.001)
        XCTAssertEqual(audio.right[4_000], -0.5, accuracy: 0.001)
        let firstRight = try XCTUnwrap(audio.right.firstIndex { abs($0) > 0.1 })
        XCTAssertEqual(firstRight, 480, accuracy: 100, "the system side sits where its own clock put it")
        XCTAssertEqual(summary.gaps, [], "jitter is not a gap")
    }

    func testPauseStopsTheSourcesAndResumeStartsThemAgain() async throws {
        let microphone = ScriptedAudioSource()
        let capture = MeetingCapture(directory: directory, microphone: microphone, systemAudio: nil)
        try await capture.start()
        microphone.deliver(constant(0.5, 1_600))
        try await capture.pause()
        let paused = await capture.state
        XCTAssertEqual(paused, .paused)
        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertFalse(microphone.isRunning, "nothing is captured while paused")
        let pendingFlushed = await capture.frameCount
        XCTAssertEqual(pendingFlushed, 1_600, "the pause flushed what was pending")

        try await capture.resume()
        XCTAssertEqual(microphone.startCount, 2)
        microphone.deliver(constant(0.5, 1_600))
        let summary = try await capture.stop()
        XCTAssertEqual(summary.frameCount, 3_200)
        XCTAssertEqual(summary.pauses.count, 1)
    }

    func testStopAndPauseAreRefusedBeforeStartAndStartIsRefusedTwice() async throws {
        let capture = MeetingCapture(directory: directory, microphone: ScriptedAudioSource(), systemAudio: nil)
        await XCTAssertThrowsErrorAsync(try await capture.stop())
        await XCTAssertThrowsErrorAsync(try await capture.pause())
        try await capture.start()
        await XCTAssertThrowsErrorAsync(try await capture.start())
        _ = try await capture.stop()
    }

    func testAMicrophoneConfigurationChangeRestartsItAndRecordsTheGap() async throws {
        let microphone = ScriptedAudioSource()
        let capture = MeetingCapture(directory: directory, microphone: microphone, systemAudio: nil)
        try await capture.start()
        microphone.deliver(constant(0.5, 1_600))
        microphone.fail(.configurationChanged)
        try await waitUntil { microphone.startCount == 2 }
        // Silence while the device was away, then audio again.
        microphone.deliver(constant(0.5, 1_600))
        let summary = try await capture.stop()
        XCTAssertEqual(summary.frameCount, 3_200)
        XCTAssertEqual(summary.gaps.count, 1)
        XCTAssertEqual(summary.gaps.first?.channel, .microphone)
        XCTAssertEqual(summary.gaps.first?.reason, .microphoneUnavailable)
    }

    func testRefusesToStartWhenTheDiskIsNearlyFull() async throws {
        let capture = MeetingCapture(
            directory: directory,
            microphone: ScriptedAudioSource(),
            systemAudio: nil,
            freeBytes: { _ in 100 * 1_024 * 1_024 }
        )
        await XCTAssertThrowsErrorAsync(try await capture.start()) { error in
            XCTAssertEqual(error as? MeetingCapture.Failure, .diskFull)
        }
    }

    func testTheDiskFillingMidRecordingStopsItCleanlyWithTheReasonKept() async throws {
        let microphone = ScriptedAudioSource()
        let free = UncheckedBox<Int64>(10 * 1_024 * 1_024 * 1_024)
        let reported = UncheckedBox<MeetingCapture.Failure?>(nil)
        let capture = MeetingCapture(
            directory: directory,
            microphone: microphone,
            systemAudio: nil,
            onFailure: { reported.value = $0 },
            freeBytes: { _ in free.value }
        )
        try await capture.start()
        free.value = 50 * 1_024 * 1_024
        // The disk is looked at once a minute of audio; deliver past that plus
        // the jitter window the aligner holds back.
        for _ in 0..<610 { microphone.deliver(constant(0.1, 1_600)) }
        try await waitUntil { reported.value == .diskFull }
        let summary = try await capture.stop()
        XCTAssertEqual(summary.endReason, .diskFull)
        XCTAssertGreaterThan(summary.frameCount, 0, "what reached disk before the stop is kept")
        let audio = try readChannels(await capture.audioURL)
        XCTAssertEqual(audio.left.count, summary.frameCount, "and the file is whole")
    }

    func testLevelsArePublishedForTheMeters() async throws {
        let microphone = ScriptedAudioSource()
        let seen = UncheckedBox<[MeetingCapture.Levels]>([])
        let capture = MeetingCapture(
            directory: directory,
            microphone: microphone,
            systemAudio: nil,
            onLevels: { seen.value.append($0) }
        )
        try await capture.start()
        microphone.deliver(constant(0.7, 1_600))
        microphone.deliver(constant(0.1, 1_600))
        _ = try await capture.stop()
        XCTAssertEqual(seen.value.count, 2)
        XCTAssertEqual(seen.value.first?.microphone, 0.7)
        XCTAssertEqual(seen.value.first?.system, 0)
        let current = await capture.levels
        XCTAssertEqual(current.microphone, 0.1)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
