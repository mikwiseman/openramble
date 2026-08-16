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

/// Proactive rewarm no longer waits for a `.normal` that a busy 16 GB machine
/// may never report again.
final class EngineRewarmPolicyTests: XCTestCase {
    func testNormalRewarmsImmediately() {
        XCTAssertEqual(EngineRewarmPolicy.settleDelay(after: .normal), .zero)
    }

    func testWarningEarnsOneSettleWindow() {
        XCTAssertEqual(EngineRewarmPolicy.settleDelay(after: .warning), .seconds(10))
    }

    func testCriticalNeverRewarmsProactively() {
        XCTAssertNil(EngineRewarmPolicy.settleDelay(after: .critical))
    }

    /// The keypress is intent: the reload rides under the voice regardless of
    /// tier. App activation is a hint and yields to critical pressure.
    func testEarlyTriggers() {
        for tier: MemoryPressureTier in [.normal, .warning, .critical] {
            XCTAssertTrue(
                EngineRewarmPolicy.allowsEarlyRewarm(trigger: .keyDown, tier: tier)
            )
        }
        XCTAssertTrue(
            EngineRewarmPolicy.allowsEarlyRewarm(trigger: .appActivation, tier: .normal)
        )
        XCTAssertTrue(
            EngineRewarmPolicy.allowsEarlyRewarm(trigger: .appActivation, tier: .warning)
        )
        XCTAssertFalse(
            EngineRewarmPolicy.allowsEarlyRewarm(trigger: .appActivation, tier: .critical)
        )
    }
}

/// A jetsam kill must not round-trip a 2.4 GB respawn into the same
/// starvation that caused it.
final class WorkerRecoveryBackoffPolicyTests: XCTestCase {
    func testNormalAndWarningProceed() {
        XCTAssertEqual(
            WorkerRecoveryBackoffPolicy.decision(tier: .normal, jitterUnit: 0.5),
            .proceed
        )
        XCTAssertEqual(
            WorkerRecoveryBackoffPolicy.decision(tier: .warning, jitterUnit: 0.5),
            .proceed
        )
    }

    func testCriticalDefersFiveToTenSecondsJittered() {
        XCTAssertEqual(
            WorkerRecoveryBackoffPolicy.decision(tier: .critical, jitterUnit: 0),
            .deferRespawn(recheckAfter: .milliseconds(5_000))
        )
        XCTAssertEqual(
            WorkerRecoveryBackoffPolicy.decision(tier: .critical, jitterUnit: 0.5),
            .deferRespawn(recheckAfter: .milliseconds(7_500))
        )
        // Out-of-range jitter clamps instead of exploding the wait.
        XCTAssertEqual(
            WorkerRecoveryBackoffPolicy.decision(tier: .critical, jitterUnit: 7),
            .deferRespawn(recheckAfter: .milliseconds(10_000))
        )
    }
}

/// Preparation dies on stall, never on slowness.
final class PreparationStallPolicyTests: XCTestCase {
    func testWedgeRequiresAFullWindlessWindow() {
        let policy = PreparationStallPolicy(stallWindow: .seconds(30))
        XCTAssertEqual(policy.verdict(elapsedSinceProgress: .zero), .keepWaiting)
        XCTAssertEqual(policy.verdict(elapsedSinceProgress: .seconds(29)), .keepWaiting)
        XCTAssertEqual(policy.verdict(elapsedSinceProgress: .seconds(30)), .wedged)
    }

    /// Production keeps a calm pulse; a test-sized ceiling still gets at least
    /// two samples before the ceiling can fire.
    func testCadenceNeverExceedsHalfTheCeiling() {
        let policy = PreparationStallPolicy()
        XCTAssertEqual(
            policy.effectiveSampleInterval(ceiling: .seconds(600)),
            .seconds(5)
        )
        XCTAssertEqual(
            policy.effectiveSampleInterval(ceiling: .milliseconds(100)),
            .milliseconds(50)
        )
    }

    /// The defaults promise what the docs promise: wedges surface in ~30 s,
    /// honest work is never raced.
    func testDefaultsMatchTheContract() {
        let policy = PreparationStallPolicy()
        XCTAssertEqual(policy.stallWindow, .seconds(30))
        XCTAssertEqual(policy.minimumProgress, .milliseconds(50))
        XCTAssertEqual(ASRWorkerDeadlines().preparation, .seconds(600))
        XCTAssertEqual(ASRWorkerDeadlines().warmup, .seconds(600))
        XCTAssertEqual(ASRWorkerDeadlines().vocabulary, .seconds(600))
    }
}

/// The gauge is the cross-isolation mirror of the last OS report.
final class MemoryPressureGaugeTests: XCTestCase {
    func testStartsNormalAndFollowsUpdates() {
        let gauge = MemoryPressureGauge()
        XCTAssertEqual(gauge.tier, .normal)
        gauge.update(.critical)
        XCTAssertEqual(gauge.tier, .critical)
        gauge.update(.warning)
        XCTAssertEqual(gauge.tier, .warning)
    }
}
