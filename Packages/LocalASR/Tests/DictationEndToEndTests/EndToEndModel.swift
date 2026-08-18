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

    /// Give the weights back before the process exits. See
    /// `EndToEndModelTeardown`.
    func releaseForTermination() async {
        guard case let .ready(transcriber) = resolved else { return }
        await transcriber.unload()
        resolved = nil
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

/// Release the shared engine before the test process exits.
///
/// The runtime destroys its Metal device from a static destructor at `exit()`.
/// A model still loaded when that runs is torn down with live buffers under it
/// and the runtime aborts — the whole suite passes and the process then dies
/// with signal 6, which is exactly how the release build failed. The
/// application does the same thing on quit; this is the test-side half of the
/// same rule.
final class EndToEndModelTeardown: NSObject, XCTestObservation {
    // XCTest refuses observer registration off the main thread, and the first
    // caller here is an async test. Hopping is enough: the observer only has to
    // exist before the bundle finishes, which is far later than the first test.
    private static let installed: Void = {
        DispatchQueue.main.async {
            XCTestObservationCenter.shared.addTestObserver(EndToEndModelTeardown())
        }
    }()

    static func install() { _ = installed }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await EndToEndModel.shared.releaseForTermination()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
    }
}

/// Take the loaded model or explicitly skip the test.
func requireEndToEndTranscriber() async throws -> LocalTranscriber {
    EndToEndModelTeardown.install()
    switch await EndToEndModel.shared.availability() {
    case let .ready(transcriber):
        return transcriber
    case let .unavailable(reason):
        throw XCTSkip("End-to-end test skipped: \(reason)")
    }
}
