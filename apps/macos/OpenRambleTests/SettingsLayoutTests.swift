import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsLayoutTests: XCTestCase {
    /// General keeps what changes how dictation behaves; everything you do
    /// once to make it work — the model, both permissions, the command-line
    /// tool — is one "Setup" pane, the same three things onboarding asks for.
    /// What you said is not a setting: dictations live in the Library, next
    /// to recordings, and Settings keeps only how many to keep.
    func testSetupIsItsOwnPane() {
        XCTAssertEqual(
            SettingsView.Pane.allCases.map(\.title),
            ["General", "Setup", "Dictionary", "About"]
        )
        XCTAssertEqual(SettingsView.Pane.setup.symbol, "checklist", "the onboarding setup step's symbol")
    }

    func testEveryPaneStaysInsideTheWindow() async throws {
        try await checkLayout(historyCount: 0)
    }

    /// A long history used to push the window past its bounds. It has left
    /// Settings, and a full one must not come back through General's rows.
    func testAFullHistoryKeepsSettingsInsideTheWindow() async throws {
        try await checkLayout(historyCount: 5)
    }

    /// Every pane is a page that scrolls inside the window: whatever its
    /// content needs, the window keeps the size the person gave it and the
    /// page stays within it.
    private func checkLayout(historyCount: Int) async throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        let store = DictationHistoryStore(directory: try AppPaths(root: harness.root).support().appending(path: "History"))
        for index in 0..<historyCount {
            _ = try store.record(text: "Take \(index). " + String(repeating: "A longer dictation to scroll. ", count: 40), audio: nil, limit: 5)
        }
        let state = harness.makeState()
        XCTAssertEqual(state.history.count, historyCount)

        for pane in SettingsView.Pane.allCases {
            let controller = NSHostingController(rootView: SettingsView(state: state, pane: pane))
            let window = NSWindow(contentViewController: controller)
            defer { window.close() }
            for size in [NSSize(width: 720, height: 540), NSSize(width: 1000, height: 720)] {
                window.setContentSize(size)
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(200))
                controller.view.layoutSubtreeIfNeeded()

                XCTAssertEqual(window.contentLayoutRect.width, size.width, accuracy: 1, "\(pane) must not widen the window")
                XCTAssertLessThanOrEqual(window.frame.height, size.height + 80, "\(pane) must not grow the window")
                let page = try XCTUnwrap(
                    descendants(of: controller.view).compactMap { $0 as? NSScrollView }.first,
                    "\(pane) is a page that scrolls"
                )
                let frame = controller.view.convert(page.bounds, from: page)
                XCTAssertLessThanOrEqual(frame.height, controller.view.bounds.height + 1, "\(pane)")
                XCTAssertGreaterThanOrEqual(frame.minY, -1, "\(pane)")
                XCTAssertLessThanOrEqual(frame.maxX, controller.view.bounds.maxX + 1, "\(pane)")
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
