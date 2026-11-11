import AVFoundation
import DictationAudio
import DictationCore
import LocalASR
import XCTest

/// Audio that the file planner takes for speech: noise whose loudness changes
/// every 20 ms, as syllables do. A steady tone would read as the room's floor.
enum SpeechLikeAudio {
    static func sample(_ index: Int, level: Float = 0.1) -> Float {
        var state = UInt32(truncatingIfNeeded: index / 320) &* 2_654_435_761 &+ 1
        state = state &* 1_664_525 &+ 1_013_904_223
        let loudness = 0.4 + 1.2 * Float(state >> 8) / Float(1 << 24)
        var noise = UInt32(truncatingIfNeeded: index) &* 747_796_405 &+ 2_891_336_453
        noise ^= noise >> 13
        noise = noise &* 1_274_126_177
        return level * loudness * (Float(noise >> 8) / Float(1 << 23) - 1)
    }

    /// A mono 16 kHz file, `seconds` long, speaking where `speaks` says so.
    static func write(
        to url: URL,
        seconds: Int,
        speaks: (_ second: Int) -> Bool = { _ in true }
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for second in 0..<seconds {
            buffer.frameLength = 16_000
            let voiced = speaks(second)
            for index in 0..<16_000 {
                buffer.floatChannelData![0][index] = voiced ? sample(second * 16_000 + index) : 0
            }
            try file.write(from: buffer)
        }
    }
}

/// A file brought into the Library becomes a recording with its sound, its
/// name and its words, without touching dictation.
@MainActor
final class RecordingImporterTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!
    private var engine: ScriptedImportRecognizer!
    private var arbiter: EngineArbiter!
    private var importer: RecordingImporter!
    private var models: [RecordingImportLanguage: URL] = [:]

    private var imported: [MeetingRecordingMetadata] = []
    private var finished: [UUID] = []
    private var failures: [(RecordingImporter.Failure, String)] = []
    private var transcripts: [UUID: [MeetingUtterance]] = [:]
    private var activities: [RecordingImporter.Activity] = []

    private let mainModel = URL(fileURLWithPath: "/models/main", isDirectory: true)
    private let hebrewModel = URL(fileURLWithPath: "/models/hebrew", isDirectory: true)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MeetingStore(
            root: root.appending(path: "Recordings", directoryHint: .isDirectory),
            trasher: { try FileManager.default.removeItem(at: $0) }
        )
        engine = ScriptedImportRecognizer()
        arbiter = EngineArbiter()
        models = [.automatic: mainModel, .hebrew: hebrewModel]
        importer = makeImporter()
    }

    override func tearDown() async throws {
        importer.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeImporter() -> RecordingImporter {
        let importer = RecordingImporter(edges: .init(
            store: store,
            recognizer: engine,
            modelDirectory: { [unowned self] in self.models[$0] },
            makePipeline: { TextPipeline(replacements: []) },
            arbiter: arbiter
        ))
        importer.onImported = { [unowned self] in self.imported.append($0) }
        importer.onFinished = { [unowned self] in self.finished.append($0) }
        importer.onFailure = { [unowned self] in self.failures.append(($0, $1)) }
        importer.onTranscript = { [unowned self] in self.transcripts[$0] = $1 }
        importer.onActivity = { [unowned self] in self.activities.append($0) }
        return importer
    }

    /// 70 s: fifteen seconds of speech, a long silence, fifteen more. Each
    /// stretch fits one piece, so there are two pieces and two paragraphs.
    private func twoPartFile(_ name: String = "Lecture.wav") throws -> URL {
        let url = root.appending(path: name)
        try SpeechLikeAudio.write(to: url, seconds: 70) { $0 < 15 || (50..<65).contains($0) }
        return url
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

    // MARK: A file becomes a recording

    func testAFileBecomesARecordingWithItsSoundItsNameAndItsWords() async throws {
        let file = try twoPartFile()
        let original = try Data(contentsOf: file)

        importer.add([file], language: .automatic)
        try await wait("the transcript") { self.finished.count == 1 }

        let recording = try XCTUnwrap(store.list().first)
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(imported.map(\.id), [recording.id], "listed as soon as its sound is in, before its words")
        XCTAssertEqual(recording.title, "Lecture", "the file's name, without its extension")
        XCTAssertEqual(recording.duration, 70, accuracy: 0.01)
        XCTAssertTrue(recording.isImported)
        XCTAssertEqual(recording.importLanguage, .automatic)
        XCTAssertFalse(recording.isMeeting, "one stream of sound is a voice note, not two sides of a call")
        XCTAssertEqual(recording.transcriptionState, .complete)
        XCTAssertNil(RecordingsPlaceholder.degradedNote(for: recording), "nothing was missed: there never was a microphone")

        // Its sound is in the store, in the store's own format.
        let audio = try XCTUnwrap(store.rawAudioURL(for: recording.id))
        XCTAssertEqual(MeetingWriter.frameCount(at: audio), 70 * 16_000)
        XCTAssertNotNil(store.peaksURL(for: recording.id), "and its waveform")
        XCTAssertEqual(try Data(contentsOf: file), original, "the file itself is only read")

        // Two stretches of speech, a long silence between: two paragraphs,
        // each where its speech is.
        let utterances = try XCTUnwrap(store.transcript(for: recording.id)?.utterances)
        XCTAssertEqual(utterances.map(\.text), ["Piece 1.", "Piece 2."])
        XCTAssertEqual(transcripts[recording.id]?.map(\.text), ["Piece 1.", "Piece 2."])
        XCTAssertEqual(utterances[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(utterances[1].start, 49, accuracy: 1.5)
        XCTAssertTrue(utterances.allSatisfy { $0.channel == .microphone })

        // The silence was never sent to the engine.
        let decoded = await engine.decodedSamples.reduce(0, +)
        XCTAssertLessThan(decoded, 36 * 16_000)

        let prepared = await engine.prepared
        XCTAssertEqual(prepared, [mainModel])
        try await wait("the engine to rest") { await !self.engine.isPrepared }
        XCTAssertTrue(importer.activity.isIdle)
    }

    func testAShortFileIsOnePiece() async throws {
        let file = root.appending(path: "Note.wav")
        try SpeechLikeAudio.write(to: file, seconds: 5)

        importer.add([file], language: .automatic)
        try await wait("the transcript") { self.finished.count == 1 }

        let recording = try XCTUnwrap(store.list().first)
        XCTAssertEqual(store.transcript(for: recording.id)?.utterances.map(\.text), ["Piece 1."])
        let samples = await engine.decodedSamples
        XCTAssertEqual(samples, [5 * 16_000])
    }

    func testAFileWithNoSpeechIsKeptAndSaysSo() async throws {
        let file = root.appending(path: "Silence.wav")
        try SpeechLikeAudio.write(to: file, seconds: 90) { _ in false }

        importer.add([file], language: .automatic)
        try await wait("the end") { self.finished.count == 1 }

        let recording = try XCTUnwrap(store.list().first)
        XCTAssertEqual(recording.transcriptionState, .complete)
        XCTAssertEqual(store.transcript(for: recording.id)?.utterances, [])
        XCTAssertEqual(RecordingsPlaceholder.transcript(for: recording.transcriptionState), .noSpeech)
        let decodes = await engine.decodes
        XCTAssertEqual(decodes, 0)
    }

    // MARK: What cannot be read

    func testWhatCannotBeReadIsSaidAndLeavesNothingBehind() async throws {
        let file = root.appending(path: "notes.m4a")
        try Data("not audio at all".utf8).write(to: file)

        importer.add([file], language: .automatic)
        try await wait("the refusal") { self.failures.count == 1 }

        XCTAssertEqual(failures.first?.0, .unreadable)
        XCTAssertEqual(failures.first?.1, "notes")
        XCTAssertEqual(store.list(), [])
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.incompleteRoot.path)) ?? []
        XCTAssertEqual(leftovers, [], "no half-made recording stays behind")
        XCTAssertTrue(importer.activity.isIdle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testOneBadFileDoesNotStopTheOthers() async throws {
        let bad = root.appending(path: "broken.mp3")
        try Data("nope".utf8).write(to: bad)
        let good = root.appending(path: "Good.wav")
        try SpeechLikeAudio.write(to: good, seconds: 5)

        importer.add([bad, good], language: .automatic)
        try await wait("the good one") { self.finished.count == 1 }

        XCTAssertEqual(failures.map(\.1), ["broken"])
        XCTAssertEqual(store.list().map(\.title), ["Good"])
    }

    // MARK: Which model

    func testAHebrewFileIsReadWithTheHebrewModel() async throws {
        let file = root.appending(path: "שיעור.wav")
        try SpeechLikeAudio.write(to: file, seconds: 5)

        importer.add([file], language: .hebrew)
        try await wait("the transcript") { self.finished.count == 1 }

        let prepared = await engine.prepared
        XCTAssertEqual(prepared, [hebrewModel])
        XCTAssertEqual(store.list().first?.importLanguage, .hebrew)
        XCTAssertEqual(store.list().first?.title, "שיעור")
    }

    func testAFileWaitsForItsModelAndStartsWhenItIsReady() async throws {
        models[.hebrew] = nil
        let file = root.appending(path: "Later.wav")
        try SpeechLikeAudio.write(to: file, seconds: 5)

        importer.add([file], language: .hebrew)
        try await wait("the file in the Library") { self.imported.count == 1 }
        try await Task.sleep(for: .milliseconds(60))

        let id = try XCTUnwrap(imported.first?.id)
        XCTAssertEqual(importer.activity.waiting, [id])
        XCTAssertTrue(importer.activity.needsModel)
        XCTAssertNil(importer.activity.transcribing)
        let before = await engine.decodes
        XCTAssertEqual(before, 0)
        XCTAssertEqual(store.metadata(for: id)?.transcriptionState, .live, "still to be transcribed, and it says so on disk")

        models[.hebrew] = hebrewModel
        importer.modelsChanged()
        try await wait("the transcript") { self.finished == [id] }
        XCTAssertFalse(importer.activity.needsModel)
    }

    func testAFileInAnotherLanguageDoesNotWaitBehindOneThatHasNoModel() async throws {
        models[.hebrew] = nil
        let hebrew = root.appending(path: "Hebrew.wav")
        let english = root.appending(path: "English.wav")
        try SpeechLikeAudio.write(to: hebrew, seconds: 5)
        try SpeechLikeAudio.write(to: english, seconds: 5)

        importer.add([hebrew], language: .hebrew)
        importer.add([english], language: .automatic)
        try await wait("the English transcript") { self.finished.count == 1 }

        XCTAssertEqual(store.metadata(for: finished[0])?.title, "English")
        XCTAssertEqual(importer.activity.waiting.count, 1)
        XCTAssertTrue(importer.activity.needsModel)
    }

    // MARK: One at a time, dictation first

    func testFilesAreTranscribedOneAtATimeInTheOrderTheyCame() async throws {
        let first = root.appending(path: "First.wav")
        let second = root.appending(path: "Second.wav")
        try SpeechLikeAudio.write(to: first, seconds: 5)
        try SpeechLikeAudio.write(to: second, seconds: 5)
        await engine.holdNextDecode()

        importer.add([first, second], language: .automatic)
        try await wait("both files in the Library") { self.imported.count == 2 }
        try await wait("the first decode") { await self.engine.isDecodeWaiting }

        XCTAssertEqual(importer.activity.transcribing, imported[0].id)
        XCTAssertEqual(importer.activity.waiting, [imported[1].id])
        XCTAssertEqual(imported.map(\.title), ["First", "Second"])

        await engine.releaseDecode()
        try await wait("both transcripts") { self.finished.count == 2 }

        XCTAssertEqual(finished, imported.map(\.id))
        let prepared = await engine.prepared
        XCTAssertEqual(prepared, [mainModel], "one load serves both")
    }

    func testAPieceDoesNotStartWhileSomeoneDictates() async throws {
        await arbiter.setDictationActive(true)
        let file = root.appending(path: "Busy.wav")
        try SpeechLikeAudio.write(to: file, seconds: 5)

        importer.add([file], language: .automatic)
        try await wait("the file in the Library") { self.imported.count == 1 }
        try await Task.sleep(for: .milliseconds(80))
        let during = await engine.decodes
        XCTAssertEqual(during, 0, "the dictation has the processor")
        XCTAssertEqual(importer.activity.transcribing, imported[0].id)

        await arbiter.setDictationActive(false)
        try await wait("the transcript") { self.finished.count == 1 }
    }

    // MARK: Endings

    func testMovingAFileToTheTrashStopsItsTranscript() async throws {
        let file = try twoPartFile()
        await engine.holdNextDecode()
        importer.add([file], language: .automatic)
        try await wait("the first decode") { await self.engine.isDecodeWaiting }
        let id = try XCTUnwrap(imported.first?.id)

        importer.cancel(id)
        try store.trash(id)
        await engine.releaseDecode()
        try await wait("the importer to rest") { self.importer.activity.isIdle }

        XCTAssertEqual(finished, [], "nothing is reported about a recording that is gone")
        XCTAssertEqual(store.list(), [])
        let decodes = await engine.decodes
        XCTAssertEqual(decodes, 1, "the second piece was never started")
    }

    func testAWaitingFileCanBeRemovedBeforeItsTurn() async throws {
        let first = root.appending(path: "First.wav")
        let second = root.appending(path: "Second.wav")
        try SpeechLikeAudio.write(to: first, seconds: 5)
        try SpeechLikeAudio.write(to: second, seconds: 5)
        await engine.holdNextDecode()
        importer.add([first, second], language: .automatic)
        try await wait("the first decode") { await self.engine.isDecodeWaiting }
        try await wait("both files in the Library") { self.imported.count == 2 }

        importer.cancel(imported[1].id)
        try store.trash(imported[1].id)
        await engine.releaseDecode()
        try await wait("the importer to rest") { self.importer.activity.isIdle }

        XCTAssertEqual(finished, [imported[0].id])
    }

    func testThreeFailuresInARowStopAndSayTheTranscriptIsNotWhole() async throws {
        // 100 s of unbroken speech: more than three pieces.
        let file = root.appending(path: "Long.wav")
        try SpeechLikeAudio.write(to: file, seconds: 100)
        await engine.failEveryDecode()

        importer.add([file], language: .automatic)
        try await wait("the end") { self.finished.count == 1 }

        let recording = try XCTUnwrap(store.list().first)
        XCTAssertEqual(recording.transcriptionState, .partial)
        XCTAssertEqual(RecordingsPlaceholder.transcript(for: recording.transcriptionState), .transcriptionDidNotFinish)
        let decodes = await engine.decodes
        XCTAssertEqual(decodes, RecordingImporter.failuresBeforeStop)
        XCTAssertNotNil(store.rawAudioURL(for: recording.id), "the sound is whole and still there")
    }

    func testAModelThatWillNotLoadIsSaidOnTheRecording() async throws {
        let file = root.appending(path: "NoEngine.wav")
        try SpeechLikeAudio.write(to: file, seconds: 5)
        await engine.failToLoad()

        importer.add([file], language: .automatic)
        try await wait("the end") { self.finished.count == 1 }

        XCTAssertEqual(store.list().first?.transcriptionState, .failed)
    }

    // MARK: A quit

    func testAnImportAQuitInterruptedIsTakenUpAgain() async throws {
        let file = try twoPartFile()
        // What a quit leaves: the sound in the store, marked as still to be
        // transcribed, and no transcript.
        let left = try await RecordingImporter.store(file: file, language: .hebrew, in: store, now: Date())
        XCTAssertEqual(left.transcriptionState, .live)
        // And one that was finished long ago: not touched again.
        let other = root.appending(path: "Done.wav")
        try SpeechLikeAudio.write(to: other, seconds: 5)
        var done = try await RecordingImporter.store(file: other, language: .automatic, in: store, now: Date())
        done.transcriptionState = .complete
        try store.write(done)

        importer.resume(store.list())
        try await wait("the transcript") { self.finished.count == 1 }

        XCTAssertEqual(finished, [left.id])
        XCTAssertEqual(store.metadata(for: left.id)?.transcriptionState, .complete)
        XCTAssertEqual(store.transcript(for: left.id)?.utterances.map(\.text), ["Piece 1.", "Piece 2."])
        let prepared = await engine.prepared
        XCTAssertEqual(prepared, [hebrewModel], "in the language it was brought in with")
    }

    /// A quit while a file is still being copied in leaves half of its
    /// sound. That must not come back as a recording: the file itself is
    /// untouched, and half of it under no name would only confuse.
    func testAHalfCopiedFileIsDroppedAndNeverComesBackAsARecording() throws {
        let id = UUID()
        let half = RecordingImporter.copyDirectory(for: id, in: store)
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        let writer = MeetingWriter(directory: half)
        try writer.open()
        try writer.append(
            microphone: (0..<16_000).map { SpeechLikeAudio.sample($0) },
            system: [Float](repeating: 0, count: 16_000)
        )
        writer.abandon()

        // The store's own crash recovery, which runs first at launch.
        XCTAssertEqual(store.recoverIncomplete(), [], "not a recording the app was making")
        XCTAssertTrue(FileManager.default.fileExists(atPath: half.path))

        importer.resume(store.list())

        XCTAssertFalse(FileManager.default.fileExists(atPath: half.path))
        XCTAssertEqual(store.list(), [])
    }

    func testStoppingForAQuitLeavesTheRecordingMarkedUnfinished() async throws {
        let file = try twoPartFile()
        await engine.holdNextDecode()
        importer.add([file], language: .automatic)
        try await wait("the first decode") { await self.engine.isDecodeWaiting }
        let id = try XCTUnwrap(imported.first?.id)

        importer.stop()
        await engine.releaseDecode()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(finished, [])
        XCTAssertEqual(store.metadata(for: id)?.transcriptionState, .live, "the next launch finds it and takes it up")
        XCTAssertNotNil(store.rawAudioURL(for: id))
    }

    // MARK: What the Library says meanwhile

    func testTheLineUnderAnImportSaysHowFarOrWhatItWaitsFor() {
        let a = UUID(), b = UUID(), c = UUID()
        var activity = RecordingImporter.Activity(transcribing: a, fraction: 0.426, waiting: [b])

        XCTAssertEqual(
            RecordingsPlaceholder.importLine(for: a, activity: activity, isDictating: false),
            "Transcribing — 42 percent."
        )
        XCTAssertEqual(
            RecordingsPlaceholder.importLine(for: a, activity: activity, isDictating: true),
            "Transcription paused while you dictate."
        )
        XCTAssertEqual(
            RecordingsPlaceholder.importLine(for: b, activity: activity, isDictating: false),
            "Waiting its turn."
        )
        XCTAssertNil(RecordingsPlaceholder.importLine(for: c, activity: activity, isDictating: false))

        activity = RecordingImporter.Activity(waiting: [b], needsModel: true)
        XCTAssertEqual(
            RecordingsPlaceholder.importLine(for: b, activity: activity, isDictating: false),
            "Waiting for the speech model."
        )
    }

    /// A file with no words yet says why where its words will be.
    func testAFileWithNoWordsYetSaysWhy() {
        let a = UUID(), b = UUID(), c = UUID()
        let busy = RecordingImporter.Activity(transcribing: a, fraction: 0.1, waiting: [b])
        XCTAssertEqual(RecordingsPlaceholder.importing(a, activity: busy), .importTranscribing)
        XCTAssertEqual(RecordingsPlaceholder.importing(b, activity: busy), .importWaiting)
        XCTAssertNil(RecordingsPlaceholder.importing(c, activity: busy), "not the importer's business")
        XCTAssertEqual(RecordingsPlaceholder.importTranscribing.title, "Transcribing")
        XCTAssertEqual(RecordingsPlaceholder.importWaiting.title, "Waiting its turn")

        let noModel = RecordingImporter.Activity(waiting: [b], needsModel: true)
        XCTAssertEqual(RecordingsPlaceholder.importing(b, activity: noModel), .waitingForModel)
    }

    func testAnImportIsCalledAnImportedFile() {
        let imported = MeetingRecordingMetadata(
            startedAt: Date(), systemAudio: SystemAudioSummary(wasRequested: false), importLanguage: .automatic
        )
        let note = MeetingRecordingMetadata(startedAt: Date(), systemAudio: SystemAudioSummary(wasRequested: false))
        XCTAssertEqual(RecordingsPlaceholder.kind(of: imported), "Imported file")
        XCTAssertEqual(RecordingsPlaceholder.kind(of: note), "Voice note")
    }

    func testTheLanguageQuestionPutsTheKeyboardsAnswerFirst() {
        let one = [URL(fileURLWithPath: "/tmp/Interview with Dana.m4a")]
        XCTAssertEqual(ImportLanguageQuestion.title(for: one), "What language is “Interview with Dana” in?")
        XCTAssertEqual(
            ImportLanguageQuestion.title(for: one + [URL(fileURLWithPath: "/tmp/b.mp3")]),
            "What language are these 2 files in?"
        )
        XCTAssertEqual(ImportLanguageQuestion.answers(suggested: .hebrew), [.hebrew, .automatic])
        XCTAssertEqual(ImportLanguageQuestion.answers(suggested: .automatic), [.automatic, .hebrew])
        XCTAssertEqual(ImportLanguageQuestion.label(for: .hebrew), "Hebrew")
        XCTAssertEqual(ImportLanguageQuestion.label(for: .automatic), "Another Language")
    }
}
