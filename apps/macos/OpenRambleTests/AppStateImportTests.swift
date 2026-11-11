import DictationAudio
import DictationCore
import LocalASR
import XCTest

/// Importing a file, as the app does it: the Library lists it, its words
/// arrive, and dictation's own model is never asked for anything.
@MainActor
final class AppStateImportTests: XCTestCase {
    private var harness: AppHarness!
    private var files: URL!

    override func setUp() async throws {
        harness = try AppHarness()
        files = FileManager.default.temporaryDirectory
            .appending(path: "import-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        harness.tearDown()
        try? FileManager.default.removeItem(at: files)
    }

    private func speech(_ name: String, seconds: Int = 5) throws -> URL {
        let url = files.appending(path: name)
        try SpeechLikeAudio.write(to: url, seconds: seconds)
        return url
    }

    private func mainEngineDirectory() throws -> URL {
        try ModelInstallLayout(manifest: try ModelManifest.bundled(), root: try AppPaths(root: harness.root).models())
            .engineDirectory
    }

    private func hebrewEngineDirectory() throws -> URL {
        try ModelInstallLayout(manifest: try ModelManifest.bundledHebrew(), root: try AppPaths(root: harness.root).models())
            .engineDirectory
    }

    private func wait(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until done: () async -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if await done() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never happened: \(what)", file: file, line: line)
    }

    func testAnImportedFileIsListedShownTranscribedAndArchived() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        await harness.importEngine.holdNextDecode()

        state.importFiles([try speech("Interview with Dana.m4a.wav")])
        try await wait("the first decode") { await self.harness.importEngine.isDecodeWaiting }

        // Its sound is in the Library before a word of it is.
        let recording = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(state.recordings.count, 1)
        XCTAssertEqual(recording.title, "Interview with Dana.m4a")
        XCTAssertEqual(state.lastFinishedRecordingID, recording.id, "what was just brought in is what the window shows")
        XCTAssertEqual(state.importActivity.transcribing, recording.id)
        XCTAssertEqual(state.transcript(for: recording.id), [])
        XCTAssertNotNil(state.recordingAudioURL(recording.id), "and it plays")

        await harness.importEngine.releaseDecode()
        try await wait("the transcript") {
            state.importActivity.isIdle && state.recordings.first?.transcriptionState == .complete
        }

        XCTAssertEqual(state.transcript(for: recording.id).map(\.text), ["Piece 1."])
        let prepared = await harness.importEngine.prepared
        XCTAssertEqual(prepared, [try mainEngineDirectory()])
        // Whoever speaks in a file, it is not "You": the text leaves the app
        // with its times and no names.
        let markdown = try XCTUnwrap(state.transcriptMarkdown(recording.id))
        XCTAssertTrue(markdown.contains("Imported file"), markdown)
        XCTAssertTrue(markdown.contains("**00:00:00**\nPiece 1."), markdown)
        XCTAssertFalse(markdown.contains("You"), markdown)
        // A finished recording keeps the compact copy of its sound, as one
        // the app recorded does.
        try await wait("the compact archive") {
            state.recordingAudioURL(recording.id)?.lastPathComponent == MeetingStore.compressedAudioFileName
        }
    }

    /// Of several files, the window shows the first: its words are the
    /// ones arriving. The last one brought in is only waiting.
    func testOfSeveralFilesTheFirstIsTheOneShown() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        await harness.importEngine.holdNextDecode()

        state.importFiles([try speech("First.wav"), try speech("Second.wav"), try speech("Third.wav")])
        try await wait("three files in the Library") { state.recordings.count == 3 }
        try await wait("the first decode") { await self.harness.importEngine.isDecodeWaiting }

        let first = try XCTUnwrap(state.recordings.first { $0.title == "First" })
        XCTAssertEqual(state.lastFinishedRecordingID, first.id)
        XCTAssertEqual(state.importActivity.transcribing, first.id)
        XCTAssertEqual(state.importActivity.waiting.count, 2)

        await harness.importEngine.releaseDecode()
        try await wait("all three transcripts") {
            state.importActivity.isIdle && state.recordings.allSatisfy { $0.transcriptionState == .complete }
        }
    }

    func testOnlyAMacWithHebrewIsAskedTheLanguage() async throws {
        try harness.installModelMarker()
        let plain = harness.makeState()
        await plain.refreshModelState()
        XCTAssertFalse(plain.importAsksForLanguage, "the main model tells its languages apart itself")

        try harness.installHebrewModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        XCTAssertTrue(state.importAsksForLanguage)
        XCTAssertEqual(state.suggestedImportLanguage, .automatic, "the keyboard is not Hebrew")
    }

    func testTheKeyboardSuggestsTheAnswer() async throws {
        try harness.installModelMarker()
        try harness.installHebrewModelMarker()
        harness.keyboardLanguages = KeyboardLanguages(current: "he", enabled: ["en", "he"])
        let state = harness.makeState()
        await state.refreshModelState()

        XCTAssertEqual(state.suggestedImportLanguage, .hebrew)
    }

    /// The reason the importer has an engine of its own: a Hebrew file on a
    /// Mac whose keyboard is English. Nothing about dictation changes.
    func testAHebrewFileIsReadInHebrewWhateverTheKeyboardIs() async throws {
        try harness.installModelMarker()
        try harness.installHebrewModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        let modelBefore = state.modelState

        state.importFiles([try speech("שיעור.wav")], language: .hebrew)
        try await wait("the transcript") {
            state.importActivity.isIdle && state.recordings.first?.transcriptionState == .complete
        }

        let prepared = await harness.importEngine.prepared
        XCTAssertEqual(prepared, [try hebrewEngineDirectory()])
        XCTAssertEqual(state.recordings.first?.importLanguage, .hebrew)
        XCTAssertEqual(state.modelState, modelBefore, "dictation's model is as it was")
    }

    func testAFileBroughtInBeforeTheModelWaitsForIt() async throws {
        let state = harness.makeState()
        await state.refreshModelState()

        state.importFiles([try speech("Early.wav")])
        try await wait("the file in the Library") { state.recordings.count == 1 }
        try await wait("the wait for a model") { state.importActivity.needsModel }
        let id = try XCTUnwrap(state.recordings.first?.id)
        XCTAssertEqual(state.importActivity.waiting, [id])
        XCTAssertEqual(
            RecordingsPlaceholder.importLine(for: id, activity: state.importActivity, isDictating: false),
            "Waiting for the speech model."
        )

        try harness.installModelMarker()
        await state.refreshModelState()
        try await wait("the transcript") {
            state.importActivity.isIdle && state.recordings.first?.transcriptionState == .complete
        }
    }

    func testAFileThatCannotBeReadIsSaidAndItsNameStaysOutOfTheJournal() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        let file = files.appending(path: "Private Client Call.m4a")
        try Data("not audio".utf8).write(to: file)

        state.importFiles([file])
        try await wait("the notice") { state.lastNotice?.kind == .failure }

        XCTAssertEqual(state.lastNotice?.reason, .recordingImport)
        XCTAssertEqual(
            state.lastNotice?.message,
            "Couldn't read “Private Client Call”. OpenRamble reads audio and video such as M4A, MP3, WAV, MP4 and MOV."
        )
        XCTAssertEqual(state.recordings, [])
        let journal = String(decoding: state.diagnostics.snapshot().data, as: UTF8.self)
        XCTAssertTrue(journal.contains("recordingImport"))
        XCTAssertFalse(journal.contains("Private"), "a file's name is the person's own")
        XCTAssertFalse(journal.contains("Client"))
    }

    func testMovingAnImportToTheTrashStopsIt() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        await harness.importEngine.holdNextDecode()
        state.importFiles([try speech("Mistake.wav", seconds: 100)])
        try await wait("the first decode") { await self.harness.importEngine.isDecodeWaiting }
        let id = try XCTUnwrap(state.recordings.first?.id)

        state.trashRecording(id)
        await harness.importEngine.releaseDecode()
        try await wait("the importer to rest") { state.importActivity.isIdle }

        XCTAssertEqual(state.recordings, [])
        let decodes = await harness.importEngine.decodes
        XCTAssertEqual(decodes, 1, "nothing more of it was transcribed")
    }

    func testAnImportAQuitInterruptedIsFinishedAtTheNextLaunch() async throws {
        try harness.installModelMarker()
        let first = harness.makeState()
        await first.refreshModelState()
        await harness.importEngine.holdNextDecode()
        first.importFiles([try speech("Lecture.wav")])
        try await wait("the first decode") { await self.harness.importEngine.isDecodeWaiting }
        let id = try XCTUnwrap(first.recordings.first?.id)

        // The quit: the engines are released, and the decode under way ends
        // with nobody to hear it.
        first.releaseEngineBeforeTermination(timeout: .milliseconds(300))
        await harness.importEngine.releaseDecode()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(first.recordings.first?.transcriptionState, .live)

        let second = harness.makeState()
        await second.refreshModelState()
        try await wait("the transcript") {
            second.importActivity.isIdle && second.recordings.first?.transcriptionState == .complete
        }
        XCTAssertEqual(second.recordings.map(\.id), [id], "the same recording, not a second copy")
        XCTAssertFalse(second.transcript(for: id).isEmpty)
    }
}
