import AppKit
import DictationCore
import SwiftUI
import XCTest

/// The Library keeps its content inside its window.
@MainActor
final class LibraryLayoutTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    /// The split view's frame inside a window of the size the app opens,
    /// after the window has laid itself out the way it does on screen.
    private func splitFrame(_ state: AppState) async throws -> (split: CGRect, window: CGRect) {
        let controller = NSHostingController(rootView: RecordingsWindow(state: state))
        let window = NSWindow(contentViewController: controller)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 660))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSSplitView }.first)
        return (controller.view.convert(split.bounds, from: split), controller.view.bounds)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// A waiting take is pinned on top of the detail. Asked for its smallest
    /// size, a split view proposes no width at all, and the pin's wrapping
    /// text then reported one word per line: the column claimed thousands of
    /// points, and the whole content slid out from under the toolbar. Seen
    /// in a screenshot, as a window with nothing in it.
    func testAPinnedWaitingTakeDoesNotPushTheLibraryOutOfItsWindow() async throws {
        try harness.installModelMarker()
        harness.typingProtection = TypingProtection(isOn: true, holder: "Terminal")
        harness.transcription.text = "The deploy passed. Let's ship the menu bar fix on Monday, right after the release notes are reviewed."
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.secureInputActive)
        harness.monitor.onPress?()
        try await Task.sleep(for: .milliseconds(150))
        harness.monitor.onRelease?()
        for _ in 0..<400 where state.waitingWords == nil || state.dictationState != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(state.waitingWords?.lastingFix, "the tallest pin: reason, words and the lasting fix")

        let frames = try await splitFrame(state)
        XCTAssertLessThanOrEqual(frames.split.height, frames.window.height + 1, "the list and the detail fit the window")
        XCTAssertGreaterThanOrEqual(frames.split.minY, -1, "and none of it has slid out of sight")
        XCTAssertLessThanOrEqual(frames.split.maxY, frames.window.maxY + 1)
    }
}
