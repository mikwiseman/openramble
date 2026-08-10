import DictationCore
import Foundation
import LocalASR
import XCTest

/// The recognition model for end-to-end tests is one for the entire process.
///
/// Downloading is expensive: the first time after installation the model is compiled under
/// neuromodule (seconds), then fractions of a second. Keep it for every test
/// would mean measuring the compiler, not the product.
///
/// The absence of a model is not a failure, but a reason to skip: in a fork without
/// installed 483 MB end-to-end tests are required to tell why, and not fail.
actor EndToEndModel {
    static let shared = EndToEndModel()

    enum Availability: Sendable {
        case ready(LocalTranscriber)
        case unavailable(String)
    }

    private var resolved: Availability?

    func availability() async -> Availability {
        if let resolved { return resolved }
        let value = await Self.resolve()
        resolved = value
        return value
    }

    private static func resolve() async -> Availability {
        let manifest: ModelManifest
        do {
            manifest = try ModelManifest.bundled()
        } catch {
            return .unavailable("\u{043D}\u{0435} \u{0447}\u{0438}\u{0442}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F} \u{0432}\u{043A}\u{043E}\u{043C}\u{043F}\u{0438}\u{043B}\u{0438}\u{0440}\u{043E}\u{0432}\u{0430}\u{043D}\u{043D}\u{044B}\u{0439} \u{043C}\u{0430}\u{043D}\u{0438}\u{0444}\u{0435}\u{0441}\u{0442} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438}: \(error)")
        }

        // The installation root is taken in the same way as asr-bench takes it: otherwise tests
        // we would look for the model in a place other than where it was placed.
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        let layout: ModelInstallLayout
        do {
            layout = try ModelInstallLayout(manifest: manifest, root: root)
        } catch {
            return .unavailable("\u{043D}\u{0435} \u{0441}\u{0442}\u{0440}\u{043E}\u{0438}\u{0442}\u{0441}\u{044F} \u{0440}\u{0430}\u{0441}\u{043A}\u{043B}\u{0430}\u{0434}\u{043A}\u{0430} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438}: \(error)")
        }

        let store = ModelStore(manifest: manifest, layout: layout)
        guard await store.refreshState().isReady else {
            return .unavailable(
                """
                The Parakeet model is not installed at \(layout.installedDirectory.path). \
                Install it with: swift build --package-path Packages/LocalASR -c release --product asr-bench \
                && ./Packages/LocalASR/.build/release/asr-bench install
                """
            )
        }

        let transcriber = LocalTranscriber()
        do {
            try await transcriber.prepare(modelDirectory: layout.engineDirectory)
        } catch {
            return .unavailable("The model is installed but could not be loaded: \(error)")
        }
        return .ready(transcriber)
    }
}

/// Take the loaded model or explicitly skip the test.
func requireEndToEndTranscriber() async throws -> LocalTranscriber {
    switch await EndToEndModel.shared.availability() {
    case let .ready(transcriber):
        return transcriber
    case let .unavailable(reason):
        throw XCTSkip("End-to-end test skipped: \(reason)")
    }
}
