import DictationCore
import Foundation
import LocalASR
import XCTest

/// The language hint must reach the engine, and not get lost along the way.
///
/// Writing check: Russian phrase recognized with the hint “en”,
/// has no right to contain the Cyrillic alphabet - the engine script filter cuts it off
/// token level. This proves the entire wiring; the quality itself
/// recognition is not evaluated here.
final class LanguageHintEndToEndTests: XCTestCase {
    private var transcriber: LocalTranscriber!
    private var workspace: URL!

    override func setUp() async throws {
        try await super.setUp()
        transcriber = try await requireEndToEndTranscriber()
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "lang-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try await super.tearDown()
    }

    func testScenario001() async throws {
        let recording = try await synthesize("\u{0421}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F} \u{043C}\u{044B} \u{043E}\u{0431}\u{0441}\u{0443}\u{0436}\u{0434}\u{0430}\u{043B}\u{0438} \u{043F}\u{043B}\u{0430}\u{043D} \u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{044B} \u{043D}\u{0430} \u{043D}\u{0435}\u{0434}\u{0435}\u{043B}\u{044E}.")

        let auto = try await transcriber.transcribe(fileURL: recording)
        let forcedEnglish = try await transcriber.transcribe(fileURL: recording, languageHint: "en")

        XCTAssertTrue(
            auto.text.contains(where: \.isCyrillic),
            "\u{0410}\u{0432}\u{0442}\u{043E}\u{043E}\u{043F}\u{0440}\u{0435}\u{0434}\u{0435}\u{043B}\u{0435}\u{043D}\u{0438}\u{0435} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{043E} \u{0443}\u{0441}\u{043B}\u{044B}\u{0448}\u{0430}\u{0442}\u{044C} \u{0440}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}: \(auto.text)"
        )
        XCTAssertFalse(
            forcedEnglish.text.contains(where: \.isCyrillic),
            "\u{041F}\u{043E}\u{0434}\u{0441}\u{043A}\u{0430}\u{0437}\u{043A}\u{0430} «en» \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043E}\u{0442}\u{0441}\u{0435}\u{0447}\u{044C} \u{043A}\u{0438}\u{0440}\u{0438}\u{043B}\u{043B}\u{0438}\u{0446}\u{0443}: \(forcedEnglish.text)"
        )
    }

    private func synthesize(_ text: String) async throws -> URL {
        let aiff = workspace.appending(path: "\(UUID().uuidString).aiff")
        let wav = workspace.appending(path: "\(UUID().uuidString).wav")
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

extension Character {
    fileprivate var isCyrillic: Bool {
        unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
