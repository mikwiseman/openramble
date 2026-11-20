import DictationCore
import LocalASR
import XCTest

/// A word the person taught is written the way they taught it.
///
/// The real model on a synthesized sentence: without the word it hears
/// "Tori", and with it the decoder completes the spelling it was given.
final class TaughtWordsEndToEndTests: XCTestCase {
    func testATaughtNameIsWrittenAsTaughtAndForgottenWhenRemoved() async throws {
        let transcriber = try await requireEndToEndTranscriber()
        let recording = try await SpeechFixtures.shared.speech(
            "The desktop app is built with Tauri, and the Mac app updates with Sparkle.",
            voice: .english
        )

        let untaught = try await transcriber.transcribe(fileURL: recording).text
        XCTAssertFalse(untaught.contains("Tauri"), "the model alone does not know the name: \(untaught)")

        await transcriber.setVocabulary(["Tauri"])
        let taught = try await transcriber.transcribe(fileURL: recording).text
        // The transcriber is shared by the whole suite.
        await transcriber.setVocabulary([])
        XCTAssertTrue(taught.contains("Tauri"), taught)
        XCTAssertTrue(taught.contains("Sparkle"), "the rest of the sentence is as it was: \(taught)")

        let again = try await transcriber.transcribe(fileURL: recording).text
        XCTAssertEqual(again, untaught, "with the word removed the take reads as before")
    }
}
