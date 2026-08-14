import XCTest

/// The recognizer remains resident unless macOS reports critical pressure.
final class EngineResidencyPolicyTests: XCTestCase {
    private func decide(
        tier: MemoryPressureTier,
        loaded: Bool = true,
        busy: Bool = false
    ) -> EngineResidencyPolicy.Decision {
        EngineResidencyPolicy.decision(
            tier: tier,
            engineLoaded: loaded,
            engineBusy: busy
        )
    }

    /// A healthy machine keeps the engine warm forever — no time-based
    /// unload exists. Manufacturing cold starts would attack the identity.
    func testNormalPressureNeverUnloads() {
        XCTAssertEqual(decide(tier: .normal), .keep)
    }

    func testUnloadedEngineNeedsNoDecision() {
        XCTAssertEqual(decide(tier: .critical, loaded: false), .keep)
    }

    /// Work in flight always wins; completion events re-evaluate.
    func testBusyEngineIsNeverUnloaded() {
        XCTAssertEqual(decide(tier: .critical, busy: true), .keep)
        XCTAssertEqual(decide(tier: .warning, busy: true), .keep)
    }

    func testCriticalUnloadsImmediatelyWhenIdle() {
        XCTAssertEqual(decide(tier: .critical), .unload)
    }

    func testWarningNeverEvictsTheLatencyCriticalWorkingSet() {
        XCTAssertEqual(decide(tier: .warning), .keep)
    }
}
