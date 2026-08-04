import DictationCore
import Foundation
import LocalASR
import XCTest

/// Подсказка языка обязана доезжать до движка, а не теряться по дороге.
///
/// Проверка по письменности: русская фраза, распознанная с подсказкой «en»,
/// не имеет права содержать кириллицу — script-фильтр движка отсекает её на
/// уровне токенов. Это доказывает всю проводку целиком; качество самого
/// распознавания здесь не оценивается.
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

    func testПодсказкаЯзыкаДоезжаетДоДвижка() async throws {
        let recording = try await synthesize("Сегодня мы обсуждали план работы на неделю.")

        let auto = try await transcriber.transcribe(fileURL: recording)
        let forcedEnglish = try await transcriber.transcribe(fileURL: recording, languageHint: "en")

        XCTAssertTrue(
            auto.text.contains(where: \.isCyrillic),
            "Автоопределение обязано услышать русский: \(auto.text)"
        )
        XCTAssertFalse(
            forcedEnglish.text.contains(where: \.isCyrillic),
            "Подсказка «en» обязана отсечь кириллицу: \(forcedEnglish.text)"
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
            throw XCTSkip("\(tool) завершился с кодом \(process.terminationStatus)")
        }
    }
}

extension Character {
    fileprivate var isCyrillic: Bool {
        unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
