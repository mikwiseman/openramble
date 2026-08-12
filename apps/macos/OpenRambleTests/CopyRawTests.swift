import DictationCore
import XCTest

/// “Copy verbatim”: what the person said, before the dictionary and cosmetics.
@MainActor
final class CopyRawTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    private func dictate(_ text: String, replacements: [DictionaryReplacement] = []) async throws -> AppState {
        try harness.installModelMarker()
        harness.transcription.text = text
        let state = harness.makeState()
        for replacement in replacements {
            state.addReplacement(spoken: replacement.spoken, written: replacement.written)
        }
        await state.refreshModelState()

        harness.monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        harness.monitor.onRelease?()
        for _ in 0..<200 where state.lastDictation == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        return state
    }

    func testScenario001() {
        XCTAssertFalse(harness.makeState().canCopyRawDictation)
    }

    /// The main thing: the verbatim text is what the person said, not what
    /// turned out after the dictionary and polisher.
    func testScenario002() async throws {
        let state = try await dictate(
            "open poust girls",
            replacements: [DictionaryReplacement(spoken: "poust girls", written: "Postgres")]
        )

        let last = try XCTUnwrap(state.lastDictation)
        XCTAssertEqual(last.provenance.raw, "open poust girls")
        XCTAssertEqual(last.insertedText, "Open Postgres")
        XCTAssertTrue(state.canCopyRawDictation)
    }

    /// Nothing was recognized - there is nothing to copy, and the menu item does not appear.
    func testScenario003() async throws {
        try harness.installModelMarker()
        harness.transcription.text = "   "
        let state = harness.makeState()
        await state.refreshModelState()

        harness.monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        harness.monitor.onRelease?()
        for _ in 0..<60 { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertFalse(state.canCopyRawDictation)
    }

    /// The latest provenance remains one slot, while completed text is retained
    /// in the short in-memory menu history.
    func testScenario004() async throws {
        let state = try await dictate("first phrase")
        XCTAssertEqual(state.lastDictation?.provenance.raw, "first phrase")

        harness.transcription.text = "second phrase"
        harness.monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        harness.monitor.onRelease?()
        for _ in 0..<200 where state.lastDictation?.provenance.raw != "second phrase" {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.lastDictation?.provenance.raw, "second phrase")
        XCTAssertEqual(state.recentDictations.map(\.text), ["Second phrase", "First phrase"])
    }

    /// When cosmetics and the dictionary changed nothing, the item would be a
    /// duplicate of the last recent dictation — it must not appear.
    func testScenario005() async throws {
        let state = try await dictate("Postgres")

        let last = try XCTUnwrap(state.lastDictation)
        XCTAssertEqual(last.provenance.raw, last.insertedText)
        XCTAssertFalse(state.canCopyRawDictation)
    }
}
