import DictationCore
import XCTest

/// The behavior of the panel: when it is on the screen, when it disappears and what it says out loud.
///
/// The window itself is not involved here - it requires a graphical session, which
/// may not be checked. Everything else is checked completely.
@MainActor
final class OverlayModelTests: XCTestCase {
    private var announcer: FakeAnnouncer!
    private var model: OverlayModel!
    private var visibility: [Bool] = []

    override func setUp() async throws {
        announcer = FakeAnnouncer()
        model = OverlayModel(
            announcer: announcer,
            noticeDuration: .milliseconds(120),
            titleDelay: .milliseconds(60)
        )
        visibility = []
        model.onVisibilityChange = { [weak self] visible in self?.visibility.append(visible) }
    }

    /// Дождаться, что автоскрытие действительно случилось.
    ///
    /// Раньше тесты спали фиксированные 220 мс при сроке показа в 120 мс.
    /// Запаса в 100 мс хватает на своей машине и не хватает загруженному
    /// раннеру: сообщение ещё висело, и проверка падала на ровном месте —
    /// так упал прогон CI на main (31569489197), хотя код был исправен.
    /// Ждём по факту и с большим запасом: быстрая машина проходит за
    /// те же миллисекунды, медленная — просто ждёт дольше.
    private func waitForNoticeToHide(
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if model.notice == nil { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("сообщение не убралось само за \(timeout)", file: file, line: line)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout)", file: file, line: line)
    }

    // MARK: - Showing and cleaning

    func testScenario001() {
        model.show(.listening, elapsed: 0)
        XCTAssertTrue(model.isVisible)

        model.hide()

        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(visibility, [true, false])
    }

    func testScenario002() {
        model.show(.preparing, elapsed: 0)
        model.show(.listening, elapsed: 0)
        model.show(.transcribing, elapsed: 1)

        XCTAssertEqual(visibility, [true], "the window is raised once per session")
    }

    // MARK: - Counter

    func testScenario003() async throws {
        model.show(.listening, elapsed: 0)
        XCTAssertTrue(model.isTicking)

        // The core communicates once at the beginning of the recording and once at the end.
        // If the panel does not count itself, the entire dictation on it is “0 s”.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThan(model.elapsed, 0.4)

        model.show(.transcribing, elapsed: model.elapsed)
        XCTAssertFalse(model.isTicking)
    }

    func testScenario004() {
        model.show(.listening, elapsed: 0)
        XCTAssertTrue(model.isTicking)

        model.hide()

        XCTAssertFalse(model.isTicking)
    }

    // MARK: - Messages

    func testScenario005() async throws {
        model.showNotice(DictationNotice(kind: .warning, message: "Text saved."))
        XCTAssertTrue(model.isVisible)

        try await waitForNoticeToHide()

        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isVisible)
    }

    /// Cleaning up after the session comes immediately after the message.
    ///
    /// If she takes the panel with her, the person does not have time to read that the text
    /// was not inserted and where is it now.
    func testScenario006() {
        model.showNotice(DictationNotice(kind: .failure, message: "Failed to insert text."))

        model.hide()

        XCTAssertTrue(model.isVisible)
        XCTAssertNotNil(model.notice)
    }

    /// Two identical messages in a row.
    ///
    /// Delayed hiding of the first one recognized “its” message from the text and carried it away
    /// from the screen the second one was shown three times shorter than expected.
    func testScenario007() async throws {
        // Your own panel with a long display period. For the general one it is 120 ms, and check
        // limited by thirty milliseconds of reserve: sleep on a loaded machine
        // flies, the message expires honestly, and the test crashes, not the product.
        // What’s important here is not “how much”, but “the second show starts counting down”
        // again” - this means the margin should be such that the difference is visible
        // during any flight.
        let announcer = FakeAnnouncer()
        let model = OverlayModel(announcer: announcer, noticeDuration: .seconds(5))
        let notice = DictationNotice(kind: .warning, message: "Dictation is currently in progress. Please wait for it to finish.")

        model.showNotice(notice)
        try await Task.sleep(for: .milliseconds(50))

        model.showNotice(notice)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(model.notice, "the second message disappeared prematurely")
        XCTAssertTrue(model.isVisible)
    }

    func testScenario008() {
        model.showNotice(DictationNotice(kind: .warning, message: "Text saved."))

        model.show(.listening, elapsed: 0)

        XCTAssertNil(model.notice)
        XCTAssertEqual(model.content.mark, .recording)
    }

    /// Delayed hiding belongs to its display.
    ///
    /// Otherwise, it would extinguish the panel of the next dictation that has already begun.
    func testScenario009() async throws {
        model.showNotice(DictationNotice(kind: .info, message: "Hour limit reached."))
        model.show(.listening, elapsed: 0)

        try await Task.sleep(for: .milliseconds(220))

        XCTAssertTrue(model.isVisible, "the ongoing dictation panel has extinguished the tail of the previous message")
    }

    // MARK: - Voice

    /// The microphone opening is a tone, never words. Speech played into an
    /// open microphone was measured in 100% of transcripts: a VoiceOver user's
    /// every dictation began with "Recording."
    func testScenario010() {
        model.show(.listening, elapsed: 0)

        XCTAssertEqual(announcer.messages, [], "nothing is spoken into an open microphone")
        XCTAssertEqual(announcer.cues, 1)
    }

    /// The counter ticks twice per second; the tone belongs to the take.
    func testScenario011() {
        model.show(.listening, elapsed: 0)
        model.show(.listening, elapsed: 1)
        model.show(.listening, elapsed: 2)

        XCTAssertEqual(announcer.cues, 1)
        XCTAssertEqual(announcer.messages, [])
    }

    func testScenario012() {
        model.show(.listening, elapsed: 0)
        model.hide()

        model.show(.listening, elapsed: 0)

        XCTAssertEqual(announcer.cues, 2, "every take opens the microphone again")
    }

    func testScenario013() {
        let notice = DictationNotice(kind: .failure, message: "Failed to record audio.")

        model.showNotice(notice)

        XCTAssertEqual(announcer.messages, ["Failed to record audio."])
        XCTAssertEqual(announcer.announcements.first?.urgent, true)
    }

    /// A take that lands inside half a second of release is one tone, no
    /// words: about nine words per take used to be spoken around it.
    func testScenario014() async throws {
        model.show(.preparing, elapsed: 0)
        model.show(.listening, elapsed: 0)
        model.show(.transcribing, elapsed: 3)
        model.show(.inserting, elapsed: 3)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(announcer.messages, [])
        XCTAssertEqual(announcer.cues, 1)
    }

    // MARK: - Hands-free

    /// Going hands-free is one more tone for VoiceOver and a lock on screen.
    func testHandsFreeIsASecondToneAndALock() {
        model.show(.listening, elapsed: 0)

        model.setHandsFree(finishKey: "Right Command")

        XCTAssertEqual(model.content.mark, .handsFree)
        XCTAssertEqual(model.content.panelWidth, 244)
        XCTAssertEqual(announcer.cues, 2)
        XCTAssertEqual(announcer.messages, [])
    }

    func testHandsFreeBelongsToOneTake() {
        model.show(.listening, elapsed: 0)
        model.setHandsFree(finishKey: "Right Command")
        model.hide()

        model.show(.listening, elapsed: 0)

        XCTAssertEqual(model.content.mark, .recording)
    }

    func testLeavingHandsFreeUnlocks() {
        model.show(.listening, elapsed: 0)
        model.setHandsFree(finishKey: "Right Command")

        model.setHandsFree(finishKey: nil)

        XCTAssertEqual(model.content.mark, .recording)
        XCTAssertEqual(announcer.cues, 2, "unlocking is not news; the take ending is")
    }

    // MARK: - One shape per take

    /// Preparing, listening and transcribing are one panel: only the mark's
    /// color moves, so the panel never changes size or re-centres mid-take.
    func testTheTakeKeepsOneShape() {
        model.show(.preparing, elapsed: 0)
        XCTAssertEqual(model.content.mark, .starting)
        XCTAssertNil(model.content.title)
        XCTAssertEqual(model.content.panelWidth, 244)

        model.show(.listening, elapsed: 0)
        XCTAssertEqual(model.content.mark, .recording)
        XCTAssertNil(model.content.title)
        XCTAssertEqual(model.content.panelWidth, 244)

        model.show(.transcribing, elapsed: 2)
        XCTAssertEqual(model.content.mark, .working)
        XCTAssertNil(model.content.title)
        XCTAssertEqual(model.content.panelWidth, 244)
    }

    /// A state that outlasts the delay earns its title, and only then words.
    func testATitleWaitsOutTheDelay() async throws {
        model.show(.transcribing, elapsed: 2)
        XCTAssertNil(model.content.title)

        try await waitUntil { self.model.hasLingered }

        XCTAssertEqual(model.content.title, "Transcribing…")
        XCTAssertEqual(model.content.panelWidth, 244)
        XCTAssertEqual(announcer.messages, ["Transcribing…"])
    }

    func testASlowMicrophoneEarnsATitleButNoWords() async throws {
        model.show(.preparing, elapsed: 0)

        try await waitUntil { self.model.hasLingered }

        XCTAssertEqual(model.content.title, "Turning on the microphone…")
        XCTAssertEqual(announcer.messages, [], "the microphone is opening: nothing is said")
    }

    /// Waiting for the model is news the moment it is true.
    func testWaitingForTheModelSaysSoAtOnce() {
        model.show(.transcribing, elapsed: 2)
        model.setWaitingForEngine(true)

        XCTAssertEqual(model.content.title, "Waking the model…")
        XCTAssertEqual(announcer.messages, ["Waiting for the speech model to load"])
    }

    /// The waveform and the clock freeze at release: that is what says the
    /// microphone closed.
    func testTheWaveformAndClockFreezeAtRelease() {
        model.show(.listening, elapsed: 4)
        model.updateInputLevel(0.5)

        model.show(.transcribing, elapsed: 4)
        model.updateInputLevel(0.9)

        XCTAssertEqual(model.waveformSamples.last, 0.5)
        XCTAssertFalse(model.isTicking)
        XCTAssertEqual(model.elapsed, 4)
    }

    func testANewTakeStartsFlat() {
        model.show(.listening, elapsed: 0)
        model.updateInputLevel(0.5)
        model.show(.transcribing, elapsed: 1)
        model.hide()

        model.show(.preparing, elapsed: 0)

        XCTAssertTrue(model.waveformSamples.allSatisfy { $0 == 0 })
    }

    /// VoiceOver never speaks while the microphone is open — not the state,
    /// and not a notice that happens to arrive mid-take either.
    func testVoiceOverNeverSpeaksWhileTheMicrophoneIsOpen() async throws {
        model.show(.preparing, elapsed: 0)
        model.showNotice(DictationNotice(kind: .info, message: "Copied."))
        model.show(.listening, elapsed: 0)
        model.showNotice(DictationNotice(kind: .warning, message: "Check the microphone."))
        try await waitForNoticeToHide()

        XCTAssertEqual(announcer.messages, [])
        XCTAssertEqual(announcer.cues, 1, "a notice expiring mid-take does not re-open the take")
    }

    /// A failure that ends the take while the panel still shows an open
    /// microphone — capture never started, the device went away, access was
    /// revoked — waits out the open microphone and is said once the take ends.
    func testAFailureThatEndsTheTakeIsSpokenOnceTheMicrophoneCloses() {
        model.show(.preparing, elapsed: 0)
        model.showNotice(DictationNotice(kind: .failure, message: "Couldn't record audio."))
        XCTAssertEqual(announcer.messages, [], "not into the opening microphone")

        model.hide()

        XCTAssertEqual(announcer.messages, ["Couldn't record audio."])
        XCTAssertEqual(announcer.announcements.first?.urgent, true)
    }

    func testADisconnectMidTakeIsSpokenOnceTheTakeEnds() async throws {
        model.show(.preparing, elapsed: 0)
        model.show(.listening, elapsed: 0)
        model.showNotice(DictationNotice(kind: .failure, message: "The microphone was disconnected."))
        model.hide()
        try await waitForNoticeToHide()

        XCTAssertEqual(announcer.messages, ["The microphone was disconnected."], "once, not again as it expires")
        XCTAssertEqual(announcer.cues, 1)
    }

    /// The natural retry after "Nothing left to insert" starts while that
    /// notice is still on screen. It is a new take all the same: the
    /// microphone opens with a tone, and the same notice ending it is news.
    func testATakeStartedUnderTheLastNoticeIsANewTake() {
        let model = OverlayModel(announcer: announcer, noticeDuration: .seconds(4), titleDelay: .seconds(4))
        let takenBack = DictationNotice(
            kind: .info,
            message: "Nothing left to insert after cleanup.",
            wordsDidNotLand: false
        )
        for _ in 0..<2 {
            model.show(.preparing, elapsed: 0)
            model.show(.listening, elapsed: 0)
            model.show(.transcribing, elapsed: 2)
            model.showNotice(takenBack)
            model.hide()
        }

        XCTAssertEqual(announcer.cues, 2, "the second take opened the microphone too")
        XCTAssertEqual(announcer.messages, [takenBack.message, takenBack.message])
    }

    /// Preparing can be merged into listening on the way to the panel. A take
    /// that arrives as listening after a closed microphone still opens it.
    func testATakeArrivingAsListeningUnderTheLastNoticeStillCues() {
        let model = OverlayModel(announcer: announcer, noticeDuration: .seconds(4))
        model.show(.listening, elapsed: 0)
        model.show(.transcribing, elapsed: 1)
        model.showNotice(DictationNotice(kind: .failure, message: "Recognition failed."))
        model.hide()

        model.show(.listening, elapsed: 0)

        XCTAssertEqual(announcer.cues, 2)
    }

    /// Locking while the microphone was still starting makes the first tone
    /// the hands-free one. A notice expiring later does not play it again.
    func testHandsFreeFromTheStartIsOneTone() async throws {
        model.show(.preparing, elapsed: 0)
        model.setHandsFree(finishKey: "Right Command")
        model.show(.listening, elapsed: 0)
        model.showNotice(DictationNotice(kind: .info, message: "Copied — to this Mac only."))
        try await waitForNoticeToHide()

        XCTAssertEqual(announcer.cues, 1)
    }

    // MARK: - Waveform

    func testScenario024() {
        model.show(.listening, elapsed: 0)

        XCTAssertEqual(model.waveformSamples.count, OverlayModel.waveformSampleCount)
        XCTAssertTrue(model.waveformSamples.allSatisfy { $0 == 0 })

        model.updateInputLevel(-1)
        model.updateInputLevel(0.25)
        model.updateInputLevel(2)

        XCTAssertEqual(model.waveformSamples.count, OverlayModel.waveformSampleCount)
        XCTAssertEqual(Array(model.waveformSamples.suffix(3)), [0, 0.25, 1])
    }

    func testScenario025() {
        model.show(.listening, elapsed: 0)
        model.updateInputLevel(0.5)
        XCTAssertEqual(model.waveformSamples.last, 0.5)

        model.hide()
        model.show(.listening, elapsed: 0)

        XCTAssertTrue(
            model.waveformSamples.allSatisfy { $0 == 0 },
            "a new dictation must not begin with the previous voice shape"
        )
    }

    func testScenario026() {
        model.show(.transcribing, elapsed: 2)
        XCTAssertTrue(model.isVisible)

        model.show(.inserting, elapsed: 2)

        XCTAssertFalse(model.isVisible, "insertion happens in the destination app, not in the HUD")
        XCTAssertFalse(model.isTicking)
    }

    func testScenario027() async throws {
        let notice = DictationNotice(kind: .warning, message: "Check the microphone.")
        model.showNotice(notice)
        // Второе объявление возможно только после того, как первый показ
        // закончился: пока он на экране, повтор считается дублем и молчит.
        // Фиксированная пауза делала исход зависящим от загрузки машины.
        try await waitForNoticeToHide()

        model.showNotice(notice)

        XCTAssertEqual(
            announcer.messages,
            ["Check the microphone.", "Check the microphone."],
            "an identical warning in a later impression must be announced again"
        )
    }

    func testNoticeDuringRecordingReturnsToLiveHUDAfterExpiry() async throws {
        model.show(.listening, elapsed: 3)
        model.showNotice(DictationNotice(kind: .info, message: "Copied."))

        try await Task.sleep(for: .milliseconds(650))

        XCTAssertEqual(model.state, .listening)
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(model.isTicking)
        XCTAssertEqual(model.content.mark, .recording)
        XCTAssertGreaterThan(model.elapsed, 3.4, "notice time must remain part of recording time")
    }

    /// A dismissed panel that stays in `.transcribing` keeps describing live
    /// animated work even after AppKit orders its window out.
    func testScenario028() {
        model.show(.transcribing, elapsed: 3)

        model.hide()

        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(
            model.state,
            .idle,
            "a dismissed panel must stop describing an active transcription"
        )
    }

    func testScenario029() {
        model.show(.transcribing, elapsed: 3)
        XCTAssertNotNil(model.visibleContent)

        model.hide()

        XCTAssertNil(
            model.visibleContent,
            "an off-screen panel must not drive RenderBox or Liquid Glass"
        )
    }

    /// A session dismissal must not erase the live state under a notice. The
    /// notice owns the panel until its timer decides whether to return to the
    /// underlying session or hide an idle panel.
    func testScenario030() {
        model.show(.listening, elapsed: 3)
        model.showNotice(DictationNotice(kind: .info, message: "Copied."))

        model.hide()

        XCTAssertEqual(model.state, .listening)
        XCTAssertTrue(model.isVisible)
        XCTAssertNotNil(model.notice)
    }

    func testScenario031() {
        model.show(.transcribing, elapsed: 3)
        model.hide()
        XCTAssertNil(model.visibleContent)

        model.show(.preparing, elapsed: 0)

        XCTAssertTrue(model.isVisible)
        XCTAssertNotNil(
            model.visibleContent,
            "a retained hosting view must rebuild the panel for the next dictation"
        )
    }

    /// Cleanup may follow a failure notice immediately. Let the person read
    /// the notice, then honor that dismissal instead of resurrecting the
    /// completed transcription underneath it.
    func testScenario032() async throws {
        model.show(.transcribing, elapsed: 3)
        model.setWaitingForEngine(true)
        model.showNotice(DictationNotice(kind: .failure, message: "Recognition failed."))

        model.hide()

        XCTAssertTrue(model.isVisible)
        XCTAssertNotNil(model.notice)
        try await waitForNoticeToHide()
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.isWaitingForEngine)
        XCTAssertFalse(model.isVisible)
        XCTAssertNil(model.visibleContent)
    }

    /// Starting another take supersedes a deferred dismissal from the previous
    /// notice. A later notice must return to that new live session.
    func testScenario033() async throws {
        model.show(.transcribing, elapsed: 3)
        model.showNotice(DictationNotice(kind: .failure, message: "Recognition failed."))
        model.hide()

        model.show(.listening, elapsed: 0)
        model.showNotice(DictationNotice(kind: .info, message: "Copied."))

        try await waitForNoticeToHide()
        XCTAssertEqual(model.state, .listening)
        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(model.isTicking)
    }
}
