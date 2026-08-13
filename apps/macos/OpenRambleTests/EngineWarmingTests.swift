import XCTest

/// The cold-suspicion rule that decides whether a keypress warms the engine
/// under the person's voice.
final class EngineWarmingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// No recorded activity means the engine's warmth is unknown — warm it.
    func testUnknownActivityWarms() {
        XCTAssertTrue(EngineWarming.shouldWarm(lastEngineActivity: nil, now: now))
    }

    /// Active dictation flow never pays for pings.
    func testRecentActivitySkipsTheWarmup() {
        XCTAssertFalse(
            EngineWarming.shouldWarm(
                lastEngineActivity: now.addingTimeInterval(-30),
                now: now
            )
        )
        XCTAssertFalse(
            EngineWarming.shouldWarm(
                lastEngineActivity: now.addingTimeInterval(-299),
                now: now
            )
        )
    }

    /// A return from real idle — where eviction happens — warms.
    func testLongIdleWarms() {
        XCTAssertTrue(
            EngineWarming.shouldWarm(
                lastEngineActivity: now.addingTimeInterval(-300),
                now: now
            )
        )
        XCTAssertTrue(
            EngineWarming.shouldWarm(
                lastEngineActivity: now.addingTimeInterval(-28_800),
                now: now
            )
        )
    }
}
