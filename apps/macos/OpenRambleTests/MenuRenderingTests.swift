import AppKit
import SwiftUI
import XCTest

/// The menu as AppKit receives it: the rows SwiftUI makes of `MenuContent`,
/// read without opening anything on screen.
///
/// Which rows exist is `MenuSections`' business and has its own tests. This
/// pins what only the real menu shows: that a chord is printed in the
/// shortcut column, that a take has a Copy twin for the Option key, and that
/// no shortcut is printed for the places.
@MainActor
final class MenuRenderingTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func dictate(_ words: String, _ state: AppState) async throws {
        let before = state.history.count
        harness.transcription.text = words
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        for _ in 0..<400 where state.history.count == before || state.dictationState != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private struct Row: Equatable, CustomStringConvertible {
        var title: String
        var shortcut: String
        var isAlternate = false
        var description: String { "\(isAlternate ? "⌥ " : "")\(title)\(shortcut.isEmpty ? "" : "  [\(shortcut)]")" }
    }

    private func shortcut(of item: NSMenuItem) -> String {
        // An alternate with no chord of its own carries a NUL key: AppKit
        // needs one to pair it with its row, and prints nothing for it.
        guard let scalar = item.keyEquivalent.unicodeScalars.first, scalar.value != 0 else { return "" }
        var text = ""
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + item.keyEquivalent.uppercased()
    }

    @available(macOS 14.4, *)
    private func rows(_ state: AppState) -> [Row] {
        let menu = NSHostingMenu(rootView: MenuContent(state: state, showOnboarding: {}))
        menu.update()
        return menu.items.filter { !$0.isSeparatorItem }.map {
            Row(title: $0.title, shortcut: shortcut(of: $0), isAlternate: $0.isAlternate)
        }
    }

    func testTheMenuPrintsOnlyShortcutsThatWorkFromAnyApp() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("needs a menu built from SwiftUI") }
        try harness.installModelMarker()
        harness.permissions.accessibilityGranted = true
        harness.permissions.microphoneGranted = true
        let state = harness.makeState()
        await state.refreshModelState()
        state.refreshPermissions()
        for words in ["First thought.", "Second thought.", "Third thought.", "Fourth thought."] {
            try await dictate(words, state)
        }

        let all = rows(state)
        print("MENU", all.map(\.description).joined(separator: " | "))
        let shown = all.filter { !$0.isAlternate }

        // The three newest takes, as their own words, the last one first
        // and with the chord that pastes it.
        XCTAssertEqual(Array(shown.dropFirst().prefix(3)), [
            Row(title: "“Fourth thought.”", shortcut: "⌃⌘V"),
            Row(title: "“Third thought.”", shortcut: ""),
            Row(title: "“Second thought.”", shortcut: ""),
        ])
        XCTAssertFalse(shown.contains { $0.title == "Copy" }, "no verb row: Option-click copies")
        XCTAssertFalse(shown.contains { $0.title.contains("First thought") }, "three at most")

        // Recording, each with its chord in the column and not in its name.
        XCTAssertTrue(shown.contains(Row(title: "Start Recording", shortcut: "⌃⌘R")), "\(shown)")
        XCTAssertTrue(shown.contains(Row(title: "Record Screen…", shortcut: "⌃⇧⌘R")), "\(shown)")

        // The places: no shortcut printed, because none works from another app.
        XCTAssertEqual(Array(shown.suffix(3)), [
            Row(title: "Library…", shortcut: ""),
            Row(title: "Settings…", shortcut: ""),
            Row(title: "Quit OpenRamble", shortcut: ""),
        ])

        // With Option held, each take reads Copy. An alternate is a second
        // item right after its row; macOS 14 has none, and the click asks.
        let alternates = all.filter(\.isAlternate)
        if #available(macOS 15.0, *) {
            XCTAssertEqual(alternates, [
                Row(title: "Copy “Fourth thought.”", shortcut: "⌃⌥⌘V", isAlternate: true),
                Row(title: "Copy “Third thought.”", shortcut: "", isAlternate: true),
                Row(title: "Copy “Second thought.”", shortcut: "", isAlternate: true),
            ])
        } else {
            XCTAssertEqual(alternates, [])
        }
    }

    /// A chord the person cleared is not printed, and one they chose is.
    func testTheMenuFollowsTheChosenShortcuts() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("needs a menu built from SwiftUI") }
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        state.recordingShortcut = nil
        state.screenRecordingShortcut = KeyCombination(keyCode: 0x69, modifiers: []) // F13

        let shown = rows(state).filter { !$0.isAlternate }
        XCTAssertTrue(shown.contains(Row(title: "Start Recording", shortcut: "")), "\(shown)")
        let screen = try XCTUnwrap(shown.first { $0.title == "Record Screen…" })
        XCTAssertFalse(screen.shortcut.isEmpty, "a bare function key is printed too")
    }
}
