import XCTest

/// The automatic unload rules, pinned exactly as agreed in review:
/// critical overrides everything except live work; warning needs persistence
/// AND idle AND the post-load hold; a healthy machine never unloads.
final class EngineResidencyPolicyTests: XCTestCase {
    private func decide(
        tier: MemoryPressureTier,
        warnings: Int = 0,
        loaded: Bool = true,
        busy: Bool = false,
        idle: TimeInterval = 3600,
        sinceLoad: TimeInterval = 3600
    ) -> EngineResidencyPolicy.Decision {
        EngineResidencyPolicy.decision(
            tier: tier,
            consecutiveWarnings: warnings,
            engineLoaded: loaded,
            engineBusy: busy,
            idleFor: idle,
            sinceLoadCompleted: sinceLoad
        )
    }

    /// A healthy machine keeps the engine warm forever — no time-based
    /// unload exists. Manufacturing cold starts would attack the identity.
    func testNormalPressureNeverUnloads() {
        XCTAssertEqual(decide(tier: .normal, idle: 86_400), .keep)
    }

    func testUnloadedEngineNeedsNoDecision() {
        XCTAssertEqual(decide(tier: .critical, loaded: false), .keep)
    }

    /// Work in flight always wins; completion events re-evaluate.
    func testBusyEngineIsNeverUnloaded() {
        XCTAssertEqual(decide(tier: .critical, busy: true), .keep)
        XCTAssertEqual(decide(tier: .warning, warnings: 5, busy: true), .keep)
    }

    /// Critical pressure overrides the post-load hysteresis (Codex's rule):
    /// release as much as possible, as soon as safely idle.
    func testCriticalUnloadsImmediatelyEvenInsideThePostLoadHold() {
        XCTAssertEqual(decide(tier: .critical, idle: 0, sinceLoad: 5), .unload)
    }

    /// One warning blip does nothing — persistence is required (Kimi's rule).
    func testSingleWarningEventIsIgnored() {
        XCTAssertEqual(decide(tier: .warning, warnings: 1), .keep)
    }

    func testPersistedWarningWithIdleAndExpiredHoldUnloads() {
        XCTAssertEqual(
            decide(tier: .warning, warnings: 2, idle: 301, sinceLoad: 601),
            .unload
        )
    }

    /// Warning-tier hysteresis: a fresh load is held for ten minutes so an
    /// ambient-pressure machine cannot oscillate between load and unload.
    func testWarningRespectsPostLoadHold() {
        let decision = decide(tier: .warning, warnings: 3, idle: 3600, sinceLoad: 60)
        guard case let .checkAgain(after) = decision else {
            return XCTFail("expected a pending boundary, got \(decision)")
        }
        XCTAssertEqual(after, 540, accuracy: 0.5, "come back exactly when the hold expires")
    }

    /// Not idle long enough: the boundary is the remaining idle window.
    func testWarningWaitsForTheIdleWindow() {
        let decision = decide(tier: .warning, warnings: 2, idle: 100, sinceLoad: 3600)
        guard case let .checkAgain(after) = decision else {
            return XCTFail("expected a pending boundary, got \(decision)")
        }
        XCTAssertEqual(after, 200, accuracy: 0.5)
    }

    /// Both windows pending: one timer, armed for the LATER boundary.
    func testPendingBoundaryIsTheLaterOfTheTwoWindows() {
        let decision = decide(tier: .warning, warnings: 2, idle: 250, sinceLoad: 60)
        guard case let .checkAgain(after) = decision else {
            return XCTFail("expected a pending boundary, got \(decision)")
        }
        XCTAssertEqual(after, 540, accuracy: 0.5, "the hold (540 s left) outlasts the idle window (50 s left)")
    }
}
