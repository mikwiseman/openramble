import DictationCore
import Foundation
import LocalASR
import XCTest

/// End-to-end testing of the acoustic prompter: real sound, both models.
///
/// The hint changes the recognition result itself, so you can check it
/// only on the live path. The transcriber here is his own, not a common one: tips, one
/// once loaded into the common one, it would change the results of all other end-to-end
/// tests depending on the launch order.
final class VocabularyBoostEndToEndTests: XCTestCase {
    private static func resolveCtcDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["WAI_CTC_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // The main path is the application's own installation: the same manifest,
        // the same amounts and layout as the user.
        let manifest = try ModelManifest.bundledVocabulary()
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let layout = try ModelInstallLayout(manifest: manifest, root: root)
        return layout.engineDirectory
    }

    private var transcriber: LocalTranscriber!
    private var workspace: URL!

    override func setUp() async throws {
        try await super.setUp()

        let ctcDirectory = try Self.resolveCtcDirectory()
        guard FileManager.default.fileExists(atPath: ctcDirectory.path) else {
            throw XCTSkip(
                "The vocabulary model is not installed at \(ctcDirectory.path). "
                    + "Install it with asr-bench install-vocab or set WAI_CTC_DIR."
            )
        }

        // The main model is searched in the same way as in other end-to-end tests,
        // but the transcriber instance is its own - see the class comment.
        guard case .ready = await EndToEndModel.shared.availability() else {
            throw XCTSkip("\u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C} Parakeet \u{043D}\u{0435} \u{0443}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043B}\u{0435}\u{043D}\u{0430} — \u{043A}\u{0430}\u{043A} \u{0438} \u{043E}\u{0441}\u{0442}\u{0430}\u{043B}\u{044C}\u{043D}\u{044B}\u{0435} \u{0441}\u{043A}\u{0432}\u{043E}\u{0437}\u{043D}\u{044B}\u{0435} \u{0442}\u{0435}\u{0441}\u{0442}\u{044B}")
        }
        let manifest = try ModelManifest.bundled()
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let layout = try ModelInstallLayout(manifest: manifest, root: root)

        transcriber = LocalTranscriber()
        try await transcriber.prepare(modelDirectory: layout.engineDirectory)
        try await transcriber.prepareVocabulary(
            modelDirectory: ctcDirectory,
            boost: .developerDefault()
        )

        workspace = FileManager.default.temporaryDirectory
            .appending(path: "vocab-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let transcriber { await transcriber.unload() }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try await super.tearDown()
    }

    /// Ordinary Russian speech with traps does not pick up the terms.
    ///
    /// “Warm” sounds like deploy, “in the center” sounds like Sentry, “comet” sounds like
    /// commit. This is precisely why these three terms are excluded from acoustic
    /// set; the test holds the dugout: if they are returned, he falls first.
    func testScenario001() async throws {
        let recording = try await synthesize(
            "\u{0422}\u{0451}\u{043F}\u{043B}\u{043E}\u{0439} \u{043E}\u{0441}\u{0435}\u{043D}\u{044C}\u{044E} \u{043C}\u{044B} \u{043E}\u{0431}\u{0435}\u{0434}\u{0430}\u{043B}\u{0438} \u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435}, \u{0430} \u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0430} \u{0432}\u{0438}\u{0441}\u{0435}\u{043B}\u{0430} \u{043D}\u{0430}\u{0434} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{043E}\u{043C}."
        )

        let result = try await transcriber.transcribe(fileURL: recording)

        for term in ["deploy", "sentry", "commit"] {
            XCTAssertFalse(
                result.text.lowercased().contains(term),
                "\u{0422}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D} «\(term)» \u{043F}\u{0440}\u{043E}\u{043B}\u{0435}\u{0437} \u{0432} \u{043E}\u{0431}\u{044B}\u{0447}\u{043D}\u{0443}\u{044E} \u{0440}\u{0443}\u{0441}\u{0441}\u{043A}\u{0443}\u{044E} \u{0444}\u{0440}\u{0430}\u{0437}\u{0443}: \(result.text)"
            )
        }
    }

    /// The term, which the replacement dictionary does not accept on principle, comes in Latin.
    ///
    /// “Postgres” model writes torn (“postgres”, “postgriz”), and
    /// flat replacement is powerless - this is a documented dictionary boundary.
    /// The acoustic hint catches the term by sound, not by spelling.
    ///
    /// The phrase is from a measured corpus: the prompt is triggered on it
    /// confirmed. Completeness for all phrases is partial and is documented in
    /// docs/benchmarks.md; The test is based on the presence of ability, and not 100%.
    func testScenario002() async throws {
        let recording = try await synthesize(
            "\u{0414}\u{0430}\u{043D}\u{043D}\u{044B}\u{0435} \u{043B}\u{0435}\u{0436}\u{0430}\u{0442} \u{0432} Postgres, \u{0430} \u{0433}\u{043E}\u{0440}\u{044F}\u{0447}\u{0438}\u{0439} \u{043A}\u{044D}\u{0448} \u{043C}\u{044B} \u{0434}\u{0435}\u{0440}\u{0436}\u{0438}\u{043C} \u{043E}\u{0442}\u{0434}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E}."
        )

        let result = try await transcriber.transcribe(fileURL: recording)

        XCTAssertTrue(
            result.text.contains("Postgres"),
            "Postgres \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{043F}\u{0440}\u{0438}\u{0439}\u{0442}\u{0438} \u{043B}\u{0430}\u{0442}\u{0438}\u{043D}\u{0438}\u{0446}\u{0435}\u{0439} \u{0438}\u{0437} \u{043F}\u{043E}\u{0434}\u{0441}\u{043A}\u{0430}\u{0437}\u{0447}\u{0438}\u{043A}\u{0430}. \u{041F}\u{0440}\u{0438}\u{0448}\u{043B}\u{043E}: \(result.text)"
        )
    }

    // MARK: - Synthesis

    private func synthesize(_ text: String) async throws -> URL {
        let aiff = workspace.appending(path: "\(UUID().uuidString).aiff")
        let wav = workspace.appending(path: "\(UUID().uuidString).wav")
        // Velocity matches the metering body: writing a broken term
        // depends on the pace of speech, and the test keeps measured behavior.
        try await run("/usr/bin/say", ["-v", "Milena", "-r", "200", "-o", aiff.path, text])
        try await run(
            "/usr/bin/afconvert",
            ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
        )
        return wav
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(tool) \u{0437}\u{0430}\u{0432}\u{0435}\u{0440}\u{0448}\u{0438}\u{043B}\u{0441}\u{044F} \u{0441} \u{043A}\u{043E}\u{0434}\u{043E}\u{043C} \(process.terminationStatus)")
        }
    }
}
