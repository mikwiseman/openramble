import DictationCore
import XCTest

/// The words a person taught the dictionary reach the recognizers, which lean
/// toward those spellings while they decode.
@MainActor
final class TaughtWordsTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    private func wait(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until done: () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await done() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never happened: \(what)", file: file, line: line)
    }

    func testOnlyTaughtWordsThatMayBoostReachTheDecoderOnce() {
        let terms = AppState.vocabularyTerms(from: [
            DictionaryReplacement(spoken: "кубернетис", written: "Kubernetes"),
            DictionaryReplacement(spoken: "кубер", written: "Kubernetes"),
            DictionaryReplacement(spoken: "коммит", written: "commit", noAcousticBoost: true),
            DictionaryReplacement(spoken: "опен рэмбл", written: "OpenRamble"),
        ])
        XCTAssertEqual(terms, ["Kubernetes", "OpenRamble"])
    }

    func testANewWordReachesTheRecognizersAndARemovedOneLeaves() async throws {
        let state = harness.makeState()
        try await wait("the launch list") { await !self.harness.importEngine.vocabularies.isEmpty }
        let atLaunch = await harness.importEngine.vocabularies.last
        XCTAssertEqual(atLaunch, [], "nobody has taught a word yet")

        state.addReplacement(spoken: "open ramble", written: "OpenRamble")
        try await wait("the taught word") { await self.harness.importEngine.vocabularies.last == ["OpenRamble"] }

        state.removeReplacements(at: IndexSet(integer: 0))
        try await wait("the word gone") { await self.harness.importEngine.vocabularies.last == [] }
    }

    func testWordsTaughtBeforeThisLaunchAreHandedOverAtLaunch() async throws {
        let first = harness.makeState()
        first.addReplacement(spoken: "tori", written: "Tauri")
        XCTAssertEqual(first.replacements.map(\.written), ["Tauri"])

        _ = harness.makeState()
        try await wait("the stored word") { await self.harness.importEngine.vocabularies.contains(["Tauri"]) }
    }
}
