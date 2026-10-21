import XCTest
@testable import DictationCore

/// A take that produced text says one thing as it ends. Its owner keeps the
/// take first and may add to that one notice (History could not keep it), so
/// the panel and VoiceOver get one notice, in order with everything else the
/// take showed, never two that hide each other.
@MainActor
final class TakeEndingNoticeTests: XCTestCase {
    private func settle(_ iterations: Int = 24) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func dictate(
        _ recognized: String,
        inserter: FakeInserter,
        overlay: FakeOverlay,
        configure: (DictationController) -> Void
    ) async -> DictationController {
        let controller = DictationController(
            capture: FakeCapture(),
            transcribe: { _ in ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: FakeSounds(),
            pipeline: { _ in TextPipeline() }
        )
        configure(controller)
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(12)
        controller.stop()
        await settle()
        return controller
    }

    private static func adding(_ sentence: String, to notice: DictationNotice) -> DictationNotice {
        DictationNotice(
            kind: notice.kind,
            message: notice.message + " " + sentence,
            recoverableText: notice.recoverableText,
            wordsDidNotLand: notice.wordsDidNotLand
        )
    }

    func testAFailedInsertionSaysOneNoticeWithWhatItsOwnerAdds() async {
        let inserter = FakeInserter()
        await inserter.setError(.accessibilityPermissionDenied)
        let overlay = FakeOverlay()
        var events: [String] = []
        var reported: [DictationNotice] = []

        let controller = await dictate("Ship it Friday.", inserter: inserter, overlay: overlay) { controller in
            controller.onTakeFinished = { _, _, _ in
                events.append("kept")
                return true
            }
            controller.amendTakeNotice = { notice in
                events.append("amended")
                return notice.map { Self.adding("Not kept.", to: $0) }
            }
            controller.onNotice = { reported.append($0) }
        }

        let said = "The text couldn't be inserted. It's saved in the menu. Not kept."
        let shown = await overlay.notices.map(\.message)
        XCTAssertEqual(shown, [said], "one notice per take")
        XCTAssertEqual(reported.map(\.message), [said])
        XCTAssertEqual(reported.first?.recoverableText, "Ship it Friday.")
        XCTAssertEqual(events, ["kept", "amended"], "the owner keeps the take before it is told what it says")
        XCTAssertEqual(controller.pendingRecovery?.text, "Ship it Friday.")
        XCTAssertEqual(controller.state, .idle)
    }

    func testATakeWhoseWordsLandedSaysOnlyWhatItsOwnerAdds() async {
        let inserter = FakeInserter()
        let overlay = FakeOverlay()
        var asked: [DictationNotice?] = []

        _ = await dictate("Ship it Friday.", inserter: inserter, overlay: overlay) { controller in
            controller.amendTakeNotice = { notice in
                asked.append(notice)
                return DictationNotice(kind: .warning, message: "Not kept.", wordsDidNotLand: false)
            }
        }

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(asked, [nil], "the words landed: the take has nothing of its own to say")
        let shown = await overlay.notices.map(\.message)
        XCTAssertEqual(shown, ["Not kept."])
    }

    func testATakeWhoseWordsLandedStaysQuietWhenItsOwnerHasNothingToAdd() async {
        let inserter = FakeInserter()
        let overlay = FakeOverlay()

        _ = await dictate("Ship it Friday.", inserter: inserter, overlay: overlay) { controller in
            controller.amendTakeNotice = { $0 }
        }

        let shown = await overlay.notices
        XCTAssertEqual(shown, [])
    }

    func testATakenBackTakeSaysOneNoticeWithWhatItsOwnerAdds() async {
        let inserter = FakeInserter()
        let overlay = FakeOverlay()
        var events: [String] = []

        _ = await dictate("Ship it Friday. Scratch that.", inserter: inserter, overlay: overlay) { controller in
            controller.onTakeFinished = { _, _, _ in
                events.append("kept")
                return true
            }
            controller.amendTakeNotice = { notice in
                events.append("amended")
                return notice.map { Self.adding("Not kept.", to: $0) }
            }
        }

        let shown = await overlay.notices.map(\.message)
        XCTAssertEqual(shown, ["Nothing left to insert after cleanup. Not kept."])
        XCTAssertEqual(events, ["kept", "amended"])
    }
}
