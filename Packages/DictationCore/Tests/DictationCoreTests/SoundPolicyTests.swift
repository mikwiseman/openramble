import XCTest
@testable import DictationCore

/// Sound means "look at me", and nothing else.
///
/// A dictation that works needs no sound: the panel already shows the
/// recording, and the text appearing at the cursor is the confirmation. A
/// chime on every start and every stop trains the person to ignore the one
/// case where a sound genuinely matters — the words did not reach the field.
/// So: a notice is surfaced ⟺ a sound plays. Silence means it worked.
@MainActor
final class SoundPolicyTests: XCTestCase {
    private actor AttentionSounds: Sounding {
        private(set) var plays = 0
        func playAttention() async { plays += 1 }
    }

    private var capture: ScriptedCapture!
    private var inserter: ScriptedInserter!
    private var overlay: CollectingOverlay!
    private var sounds: AttentionSounds!

    override func setUp() async throws {
        capture = ScriptedCapture()
        inserter = ScriptedInserter()
        overlay = CollectingOverlay()
        sounds = AttentionSounds()
    }

    private func makeController(
        recognized: String = "words",
        allowPressReturnCommand: Bool = false
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in
                ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { TextPipeline(allowPressReturnCommand: allowPressReturnCommand) }
        )
    }

    private func runFullDictation(_ controller: DictationController) async {
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        for _ in 0..<12 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        controller.stop()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The whole point: a dictation that lands is silent from beginning to end.
    func testSuccessfulDictationIsCompletelySilent() async throws {
        let controller = makeController()
        await runFullDictation(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["Words"], "the text must have landed")
        let plays = await sounds.plays
        XCTAssertEqual(plays, 0, "success needs no sound — the text at the cursor is the receipt")
    }

    /// The one case the person must not miss: the words did not reach the field.
    func testTextThatDidNotLandSounds() async throws {
        let controller = makeController()
        await inserter.setInsertError(.targetUnavailable)
        await runFullDictation(controller)

        let plays = await sounds.plays
        XCTAssertEqual(plays, 1, "a person looking at their editor learns of this only by ear")
        let notices = await overlay.notices
        XCTAssertTrue(
            notices.contains { $0.recoverableText != nil },
            "and the panel offers the text back: \(notices.map(\.message))"
        )
    }

    /// Spoke, and nothing came out: no text landed, so it sounds.
    func testEmptyRecognitionSounds() async throws {
        let controller = makeController(recognized: "")
        await runFullDictation(controller)

        let plays = await sounds.plays
        XCTAssertEqual(plays, 1)
    }

    /// Escape is the person's own decision. They are already looking at the
    /// screen; a sound here would be the app arguing with them.
    func testCancellationStaysSilent() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        for _ in 0..<12 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        controller.cancel()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        let plays = await sounds.plays
        XCTAssertEqual(plays, 0)
    }

    /// The words landed; only the Return press failed. The person sees their
    /// text in the field — a warning is shown, but sounding it would be an
    /// alarm about nothing lost.
    func testLandedTextWithFailedReturnStaysSilent() async throws {
        await inserter.setReturnError(.modifiersStillHeld)
        let controller = makeController(
            recognized: "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}",
            allowPressReturnCommand: true
        )
        await runFullDictation(controller)

        let inserted = await inserter.insertedTexts
        XCTAssertFalse(inserted.isEmpty, "the text itself must have landed")
        let notices = await overlay.notices
        XCTAssertTrue(notices.contains { $0.kind == .warning }, "the warning is still shown")
        let plays = await sounds.plays
        XCTAssertEqual(plays, 0, "words in the field need no alarm")
    }

    /// Exactly one sound per session, no matter how many notices the failure
    /// path produces on the way out.
    func testOneSessionNeverSoundsTwice() async throws {
        let controller = makeController()
        await inserter.setInsertError(.targetUnavailable)
        await runFullDictation(controller)
        let first = await sounds.plays

        await inserter.setInsertError(nil)
        await runFullDictation(controller)
        let second = await sounds.plays

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1, "the healthy dictation that followed added nothing")
    }
}
