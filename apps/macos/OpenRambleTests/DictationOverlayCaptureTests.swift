import AppKit
import DictationCore
import XCTest

/// The dictation panel must be screenshottable.
///
/// Failure messages are shown in this panel and nowhere else. A person who
/// hits an error and wants to report it needs a picture of it — and macOS
/// answers a capture attempt on an excluded window with the unexplained
/// "Unable to capture window image". This test exists because the panel
/// really did carry `.none` once, and nothing noticed for months.
@MainActor
final class DictationOverlayCaptureTests: XCTestCase {
    private final class SilentAnnouncer: AccessibilityAnnouncing, @unchecked Sendable {
        func announce(_ message: String, urgent: Bool) {}
    }

    func testPanelIsNotExcludedFromScreenCapture() async throws {
        let overlay = DictationOverlay(announcer: SilentAnnouncer())
        await overlay.present(.listening, elapsed: 0)

        let panel = try XCTUnwrap(
            NSApp.windows.first { $0 is NSPanel && $0.level == .statusBar },
            "the dictation panel should exist once presented"
        )
        XCTAssertEqual(
            panel.sharingType, .readOnly,
            "the panel shows failure messages — a person must be able to screenshot them"
        )

        await overlay.dismiss()
    }
}
