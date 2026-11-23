import DictationCore
import UIKit
import XCTest
@testable import OpenRamble

@MainActor
final class DictationTests: XCTestCase {
    func testATakeIsWrittenThroughTheMacsTextPipelineAndCopied() async throws {
        let rig = await Rig()
        defer { rig.clean() }
        await rig.engine.say("um so this is uh the first take")

        await rig.dictation.start()
        XCTAssertTrue(rig.dictation.isRecording)
        await rig.dictation.finish()

        let take = try XCTUnwrap(rig.store.takes.last)
        XCTAssertEqual(take.state, .written)
        // The same cleanup the Mac applies before it types: hesitations go,
        // the sentence gets its capital and its full stop.
        let expected = TextPipeline(mode: .prose).run("um so this is uh the first take").output.text
        XCTAssertEqual(take.text, expected)
        XCTAssertFalse(take.text.lowercased().contains("um "), "hesitations are removed")
        XCTAssertEqual(take.duration, 2)
        XCTAssertNotNil(take.writtenIn)
        XCTAssertNotNil(rig.store.audioURL(for: take), "the recording is kept beside the words")
        XCTAssertEqual(UIPasteboard.general.string, take.text, "copied, ready to paste")
        XCTAssertEqual(rig.dictation.notice, .copied)
    }

    func testCopyingCanBeTurnedOff() async throws {
        let rig = await Rig()
        defer { rig.clean() }
        UIPasteboard.general.items = []
        rig.dictation.copiesEachTake = false

        await rig.dictation.start()
        await rig.dictation.finish()

        XCTAssertEqual(rig.store.takes.last?.state, .written)
        XCTAssertNil(UIPasteboard.general.string)
        XCTAssertEqual(rig.defaults.bool(forKey: Dictation.copiesKey), false, "the choice is remembered")
    }

    func testATakeIsKeptFromTheMomentRecordingStarts() async throws {
        let rig = await Rig()
        defer { rig.clean() }

        await rig.dictation.start()

        // If the app were ended now, the audio would be found on the next launch.
        let reopened = TakeStore(root: rig.root)
        XCTAssertEqual(reopened.unfinished.count, 1)
        XCTAssertNotNil(reopened.audioURL(for: reopened.unfinished[0]))
        XCTAssertEqual(rig.dictation.recordingID, reopened.unfinished[0].id, "the list hides the take being recorded")
    }

    func testUnfinishedTakesAreWrittenWhenTheModelOpens() async throws {
        let rig = await Rig(modelReady: false)
        defer { rig.clean() }
        // A take left by an earlier run that ended mid-writing.
        let take = Take(duration: 1, state: .writing, audioFileName: "left.wav")
        try writeTone(to: rig.store.audioFolder.appending(path: "left.wav"), seconds: 1)
        rig.store.insert(take)

        await rig.dictation.modelBecameReady(at: rig.root)

        XCTAssertEqual(rig.store.take(take.id)?.state, .written)
    }

    func testAFailureKeepsTheAudioAndCanBeTriedAgain() async throws {
        let rig = await Rig()
        defer { rig.clean() }
        await rig.engine.fail(.inferenceFailed("boom"))

        await rig.dictation.start()
        await rig.dictation.finish()

        let failed = try XCTUnwrap(rig.store.takes.last)
        guard case .failed = failed.state else { return XCTFail("expected a failure, got \(failed.state)") }
        XCTAssertNotNil(rig.store.audioURL(for: failed), "never silently drop a recording")

        await rig.engine.fail(nil)
        await rig.dictation.write(failed.id)

        XCTAssertEqual(rig.store.take(failed.id)?.state, .written)
    }

    func testSilenceIsSaidNotHidden() async throws {
        let rig = await Rig()
        defer { rig.clean() }
        await rig.engine.say("")

        await rig.dictation.start()
        await rig.dictation.finish()

        XCTAssertEqual(rig.store.takes.last?.state, .silent)
        XCTAssertNotEqual(rig.dictation.notice, .copied)
    }

    func testATapIsNotATake() async throws {
        let rig = await Rig()
        defer { rig.clean() }
        rig.recorder.seconds = 0.2

        await rig.dictation.start()
        await rig.dictation.finish()

        XCTAssertTrue(rig.store.takes.isEmpty)
        XCTAssertEqual(rig.dictation.notice, .message("Too short to hear anything."), "the person is told")
        let runs = await rig.engine.runs
        XCTAssertEqual(runs, 0)
    }

    func testDiscardThrowsTheTakeAway() async throws {
        let rig = await Rig()
        defer { rig.clean() }

        await rig.dictation.start()
        rig.dictation.discard()

        XCTAssertFalse(rig.dictation.isRecording)
        XCTAssertTrue(rig.store.takes.isEmpty)
        XCTAssertTrue(rig.recorder.discarded)
        let files = try FileManager.default.contentsOfDirectory(atPath: rig.store.audioFolder.path)
        XCTAssertTrue(files.isEmpty)
    }

    func testAnInterruptionStopsAndWritesTheTake() async throws {
        let rig = await Rig()
        defer { rig.clean() }

        await rig.dictation.start()
        rig.recorder.onInterruption?()
        for _ in 0..<100 where rig.store.takes.last?.state != .written {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(rig.dictation.isRecording)
        XCTAssertEqual(rig.store.takes.last?.state, .written, "a phone call does not lose the take")
    }

    func testAMicrophoneTheSystemRefusesIsExplained() async throws {
        let rig = await Rig()
        defer { rig.clean() }
        rig.recorder.failure = RecordingError.microphoneDenied

        await rig.dictation.start()

        XCTAssertFalse(rig.dictation.isRecording)
        XCTAssertEqual(rig.dictation.notice, .microphoneDenied)
        XCTAssertTrue(rig.store.takes.isEmpty)
    }

    func testAnOpenedFileBecomesATakeAndIsNotCopiedOverTheClipboard() async throws {
        let rig = await Rig()
        defer { rig.clean() }
        UIPasteboard.general.items = []
        let file = rig.root.appending(path: "memo.wav")
        try writeTone(to: file, seconds: 3)

        let take = await rig.dictation.open(file: file)

        XCTAssertEqual(take?.state, .written)
        XCTAssertEqual(take?.source, .file)
        XCTAssertEqual(take?.duration ?? 0, 3, accuracy: 0.01)
        XCTAssertNil(UIPasteboard.general.string, "a file the person opened does not replace what they copied")
    }

    func testTheModelMustBeOpenToWrite() async throws {
        let rig = await Rig(modelReady: false)
        defer { rig.clean() }

        await rig.dictation.start()
        await rig.dictation.finish()

        let take = try XCTUnwrap(rig.store.takes.last)
        XCTAssertEqual(take.state, .failed("The voice model is not open yet."))
        XCTAssertNotNil(rig.store.audioURL(for: take))
    }
}
