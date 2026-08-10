import Foundation
import LocalASR
import XCTest

/// What a person will hear in response to a key press that does not start anything.
///
/// Silence in response to a click is indistinguishable from a broken application. Each
/// the reason must be named in words, and this is checked by a table.
final class DictationReadinessTests: XCTestCase {
    private func reason(
        accessibility: Bool = true,
        microphone: Bool = true,
        model: ModelState = .ready(directory: URL(fileURLWithPath: "/tmp/engine")),
        engineReady: Bool = true
    ) -> String? {
        DictationReadiness.reason(
            accessibilityGranted: accessibility,
            microphoneGranted: microphone,
            modelState: model,
            isEngineReady: engineReady
        )
    }

    func testScenario001() {
        XCTAssertNil(reason())
    }

    /// The warm-up window is the very place where there was deaf silence before: everything
    /// installed, everything is issued, but the key does not work for tens of seconds.
    func testScenario002() {
        let message = reason(engineReady: false)

        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("20–40 seconds") == true, "without a deadline it is not clear whether to wait or restart")
    }

    func testScenario003() {
        XCTAssertEqual(
            reason(microphone: false),
            "Dictation needs microphone access. Open Settings → General → Permissions."
        )
    }

    func testScenario004() {
        XCTAssertTrue(reason(accessibility: false)?.contains("Accessibility") == true)
    }

    func testScenario005() {
        XCTAssertTrue(reason(model: .notInstalled)?.contains("model isn't downloaded") == true)
    }

    func testScenario006() {
        XCTAssertEqual(
            reason(model: .downloading(receivedBytes: 10, totalBytes: 100)),
            "The recognition model is still downloading."
        )
    }

    func testScenario007() {
        XCTAssertTrue(reason(model: .repairRequired("checksum"))?.contains("needs repair") == true)
        XCTAssertTrue(reason(model: .failed(.cancelled))?.contains("needs repair") == true)
    }

    /// Permissions are more important than the model: without them, no model will help, and call
    /// downloading a person half a gigabyte before he gave out the microphone is a lie.
    func testScenario008() {
        let message = reason(microphone: false, model: .notInstalled)

        XCTAssertTrue(message?.contains("microphone") == true)
        XCTAssertFalse(message?.contains("model") == true)
    }

    /// A finished model without a warmed-up engine is not “the model is not installed.”
    func testScenario009() {
        let message = reason(model: .ready(directory: URL(fileURLWithPath: "/tmp/engine")), engineReady: false)

        XCTAssertFalse(message?.contains("isn't downloaded") == true)
    }
}
