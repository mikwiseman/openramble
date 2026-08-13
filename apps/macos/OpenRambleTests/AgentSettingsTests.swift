import XCTest

@MainActor
final class AgentSettingsTests: XCTestCase {
    func testAgentTranscriptionIsExplicitOptInAndPersists() throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        let state = harness.makeState()

        XCTAssertFalse(state.agentTranscriptionEnabled)
        state.agentTranscriptionEnabled = true

        XCTAssertTrue(harness.defaults.bool(forKey: "agentTranscriptionEnabled"))
    }
}
