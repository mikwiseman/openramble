import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsLayoutTests: XCTestCase {
    /// General keeps what changes how dictation behaves; everything you do
    /// once to make it work — the model, both permissions, the command-line
    /// tool — is one "Setup" pane, the same three things onboarding asks for.
    func testSetupIsItsOwnPane() {
        XCTAssertEqual(
            SettingsView.Pane.allCases.map(\.title),
            ["General", "Setup", "Dictation History", "Dictionary", "About"]
        )
        XCTAssertEqual(SettingsView.Pane.setup.symbol, "checklist", "the onboarding setup step's symbol")
    }

    func testEmptyHistoryKeepsSettingsInsideTheWindow() async throws {
        try await checkLayout(historyCount: 0)
    }

    func testPopulatedHistoryKeepsSettingsInsideTheWindow() async throws {
        try await checkLayout(historyCount: 5)
    }

    private func checkLayout(historyCount: Int) async throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        let store = DictationHistoryStore(directory: try AppPaths(root: harness.root).support().appending(path: "History"))
        for index in 0..<historyCount {
            _ = try store.record(text: "Take \(index). " + String(repeating: "A longer dictation to scroll. ", count: 40), audio: nil, limit: 5)
        }
        let state = harness.makeState()
        XCTAssertEqual(state.history.count, historyCount)
        let controller = NSHostingController(rootView: SettingsView(state: state))
        let window = NSWindow(contentViewController: controller)
        defer { window.close() }
        window.setContentSize(NSSize(width: 780, height: 580))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))

        let sidebar = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(sidebar.numberOfRows, SettingsView.Pane.allCases.count)
        for size in [NSSize(width: 720, height: 540), NSSize(width: 1000, height: 720)] {
            window.setContentSize(size)
            // Re-enter history from every other pane, including after resizing.
            for row in [2, 0, 2, 1, 2, 3, 2, 4, 2] {
                sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                try await Task.sleep(for: .milliseconds(200))
                controller.view.layoutSubtreeIfNeeded()

                let split = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSSplitView }.first)
                let frame = controller.view.convert(split.bounds, from: split)
                XCTAssertLessThanOrEqual(frame.height, controller.view.bounds.height + 1)
                XCTAssertGreaterThanOrEqual(frame.minY, -1)
                XCTAssertTrue(sidebar.visibleRect.contains(sidebar.rect(ofRow: 0)), "General must remain reachable")
                XCTAssertTrue(sidebar.visibleRect.contains(sidebar.rect(ofRow: 4)), "About must remain reachable")
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
