import XCTest
@testable import DictationCore

/// A take in which the model found no words is never thrown away in silence.
///
/// Sound with no words is kept for History, where it can be played and
/// recognized again. Silence is not kept — a row of nothing helps nobody — but
/// it names the microphone it came from, because a muted or wrong input is the
/// usual reason a held key records nothing.
@MainActor
final class EmptyTakeTests: XCTestCase {
    private var capture: FakeCapture!
    private var inserter: FakeInserter!
    private var overlay: FakeOverlay!
    private var sounds: FakeSounds!
    private var controller: DictationController!
    private var archived: [(text: String, url: URL)] = []

    /// Room noise, well under the speech floor.
    private let quiet = [Float](repeating: 0.001, count: 16_000)

    override func setUp() async throws {
        capture = FakeCapture()
        inserter = FakeInserter()
        overlay = FakeOverlay()
        sounds = FakeSounds()
        archived = []
        controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { _ in TextPipeline() }
        )
        controller.onTakeFinished = { [weak self] text, url in self?.archived.append((text, url)) }
    }

    private func dictate() async {
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        for _ in 0..<12 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        controller.stop()
        for _ in 0..<24 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testAnEmptyTakeWithSoundIsKeptInHistoryWithoutText() async {
        await capture.setBufferedSamples(quiet + [0.1] + quiet)

        await dictate()

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        let plays = await sounds.attentionPlays
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(archived.map(\.text), [""], "kept so it can be heard and recognized again")
        XCTAssertEqual(archived.map(\.url.lastPathComponent), ["fake-take.wav"])
        XCTAssertEqual(notices.count, 1, "\(notices)")
        XCTAssertEqual(notices.first?.kind, .info)
        XCTAssertEqual(notices.first?.message, "Nothing was recognized — nothing was inserted.")
        XCTAssertEqual(notices.first?.wordsDidNotLand, true)
        XCTAssertEqual(plays, 1)
    }

    func testAnEmptyTakeOfSilenceNamesTheMicrophoneAndKeepsNothing() async {
        await capture.setBufferedSamples(quiet)
        controller.microphoneName = { "Test Mic" }

        await dictate()

        let notices = await overlay.notices
        let plays = await sounds.attentionPlays
        XCTAssertTrue(archived.isEmpty, "silence is not kept")
        XCTAssertEqual(notices.count, 1, "\(notices)")
        XCTAssertEqual(notices.first?.message, "Heard only silence from Test Mic.")
        // Orange, like the notice for a held key that recorded no audio at
        // all: a muted, dead or wrong input needs the person to act.
        XCTAssertEqual(notices.first?.kind, .warning)
        XCTAssertEqual(notices.first?.wordsDidNotLand, true)
        XCTAssertNil(notices.first?.recoveryAudio)
        XCTAssertEqual(plays, 1)
    }

    /// Without a name the words change, never the kind: it is the same
    /// silence, and it is counted the same way.
    func testSilenceFromAnUnnamedMicrophoneSaysNothingWasRecognized() async {
        await capture.setBufferedSamples(quiet)
        controller.microphoneName = { nil }

        await dictate()

        let notices = await overlay.notices
        XCTAssertTrue(archived.isEmpty)
        XCTAssertEqual(notices.map(\.message), ["Nothing was recognized — nothing was inserted."])
        XCTAssertEqual(notices.first?.kind, .warning)
        XCTAssertEqual(notices.first?.wordsDidNotLand, true)
    }

    /// Without the samples (a take longer than the in-memory bound) there is
    /// no telling silence from sound, so the take is kept.
    func testAnEmptyTakeWithoutPCMIsKeptRatherThanCalledSilence() async {
        await capture.setBufferedSamples(nil)
        controller.microphoneName = { "Test Mic" }

        await dictate()

        let notices = await overlay.notices
        XCTAssertEqual(archived.map(\.text), [""])
        XCTAssertEqual(notices.map(\.message), ["Nothing was recognized — nothing was inserted."])
    }
}
