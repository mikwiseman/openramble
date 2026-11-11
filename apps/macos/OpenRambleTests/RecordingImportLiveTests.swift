import DictationAudio
import DictationCore
import LocalASR
import XCTest

/// The importer with the real engine, the real models and real files.
///
/// Skipped unless `OPENRAMBLE_IMPORT_CHECK` names a folder that holds
///
///     main/        a models root with the main model installed
///     hebrew/      a models root with the Hebrew model installed
///     english.*    files of English speech, in any formats
///     hebrew.*     files of Hebrew speech, in any formats
///
/// so the suite stays hermetic everywhere else. Run it with
/// `TEST_RUNNER_OPENRAMBLE_IMPORT_CHECK=<folder> xcodebuild … test
/// -only-testing:OpenRambleTests/RecordingImportLiveTests`.
@MainActor
final class RecordingImportLiveTests: XCTestCase {
    func testRealFilesInEveryFormatAreTranscribedInTheirLanguage() async throws {
        guard let path = ProcessInfo.processInfo.environment["OPENRAMBLE_IMPORT_CHECK"] else {
            throw XCTSkip("no folder of real models and files was given")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let mainModel = try ModelInstallLayout(
            manifest: try ModelManifest.bundled(), root: folder.appending(path: "main", directoryHint: .isDirectory)
        ).engineDirectory
        let hebrewModel = try ModelInstallLayout(
            manifest: try ModelManifest.bundledHebrew(), root: folder.appending(path: "hebrew", directoryHint: .isDirectory)
        ).engineDirectory
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            // `hebrew` with no extension is the models folder, not a file.
            .filter { !$0.pathExtension.isEmpty && ["english", "hebrew"].contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)

        let root = FileManager.default.temporaryDirectory
            .appending(path: "import-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root, trasher: { try FileManager.default.removeItem(at: $0) })
        let engine = LocalTranscriber()
        let importer = RecordingImporter(edges: .init(
            store: store,
            recognizer: engine,
            modelDirectory: { $0 == .hebrew ? hebrewModel : mainModel },
            makePipeline: { TextPipeline(replacements: []) },
            arbiter: EngineArbiter()
        ))
        var finished = 0
        var refused: [String] = []
        importer.onFinished = { _ in finished += 1 }
        importer.onFailure = { _, name in refused.append(name) }

        // English and Hebrew alternate in the queue, so the one engine has
        // to change models between files, both ways.
        for file in files {
            let hebrew = file.deletingPathExtension().lastPathComponent == "hebrew"
            importer.add([file], language: hebrew ? .hebrew : .automatic)
        }
        for _ in 0..<12_000 where finished + refused.count < files.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(refused, [], "every one of these formats is readable")
        XCTAssertEqual(finished, files.count)

        let recordings = store.list()
        XCTAssertEqual(recordings.count, files.count)
        for recording in recordings {
            let text = store.transcript(for: recording.id)?.utterances.map(\.text).joined(separator: " ") ?? ""
            let hebrewLetters = text.unicodeScalars.filter { (0x05D0...0x05EA).contains($0.value) }.count
            let latinLetters = text.unicodeScalars.filter { (0x41...0x7A).contains($0.value) }.count
            print("import-live \(recording.importLanguage?.rawValue ?? "?") \(String(format: "%.1f", recording.duration)) s: \(text)")
            XCTAssertEqual(recording.transcriptionState, .complete)
            XCTAssertFalse(text.isEmpty)
            // The right alphabet, overwhelmingly. Not exclusively: a Hebrew
            // speaker's acronym may be written in Latin letters.
            if recording.importLanguage == .hebrew {
                XCTAssertGreaterThan(hebrewLetters, 10, text)
                XCTAssertGreaterThan(hebrewLetters, 20 * latinLetters, text)
            } else {
                XCTAssertGreaterThan(latinLetters, 10, text)
                XCTAssertGreaterThan(latinLetters, 20 * hebrewLetters, text)
            }
            let utterances = store.transcript(for: recording.id)?.utterances ?? []
            print("import-live paragraphs \(utterances.count), first at \(utterances.first?.start ?? -1), last ends \(utterances.last?.end ?? -1)")
        }
        let loaded = await engine.isPrepared
        XCTAssertFalse(loaded, "the model's memory is given back when the last file is done")
    }
}
