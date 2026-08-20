import XCTest

/// Stopping on silence, and the several ways that could go wrong.
final class SilencePolicyTests: XCTestCase {
    private let loud: Float = 0.5
    private let quiet: Float = 0.001

    private func at(_ seconds: Double, from start: ContinuousClock.Instant) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(Int(seconds * 1000)))
    }

    /// Speech, then a long enough pause, ends the take.
    func testScenario001() {
        var policy = SilencePolicy()
        let start = ContinuousClock.now
        XCTAssertFalse(policy.observe(peak: loud, at: start))
        XCTAssertFalse(policy.observe(peak: quiet, at: at(0.5, from: start)))
        XCTAssertFalse(policy.observe(peak: quiet, at: at(1.5, from: start)))
        XCTAssertTrue(policy.observe(peak: quiet, at: at(2.6, from: start)))
    }

    /// Silence before a word is said ends nothing.
    ///
    /// Starting hands-free in a quiet room would otherwise stop the recording
    /// before the person began, and the feature would look broken.
    func testScenario002() {
        var policy = SilencePolicy()
        let start = ContinuousClock.now
        for second in 0...10 {
            XCTAssertFalse(
                policy.observe(peak: quiet, at: at(Double(second), from: start)),
                "no speech yet, so there is nothing to end"
            )
        }
    }

    /// A pause between sentences is not an ending.
    ///
    /// The quiet clock restarts on the next word, so someone who thinks for a
    /// second and carries on keeps their recording.
    func testScenario003() {
        var policy = SilencePolicy()
        let start = ContinuousClock.now
        _ = policy.observe(peak: loud, at: start)
        _ = policy.observe(peak: quiet, at: at(1.0, from: start))
        XCTAssertFalse(policy.observe(peak: loud, at: at(1.8, from: start)))
        // The quiet clock restarts at the first quiet frame after the word —
        // here 3.0 — so two seconds run out at 5.0, not measured from the word.
        XCTAssertFalse(policy.observe(peak: quiet, at: at(3.0, from: start)))
        XCTAssertFalse(policy.observe(peak: quiet, at: at(4.0, from: start)))
        XCTAssertTrue(policy.observe(peak: quiet, at: at(5.1, from: start)))
    }

    /// A new take starts from nothing, or the previous one's silence would end
    /// it before a word was said.
    func testScenario004() {
        var policy = SilencePolicy()
        let start = ContinuousClock.now
        _ = policy.observe(peak: loud, at: start)
        _ = policy.observe(peak: quiet, at: at(1.0, from: start))
        policy.reset()
        XCTAssertFalse(policy.hasHeardSpeech)
        XCTAssertNil(policy.quietSince)
        XCTAssertFalse(policy.observe(peak: quiet, at: at(9.0, from: start)))
    }

    /// The threshold separates a room from a voice rather than silence from
    /// sound: a quiet room is never exactly zero.
    func testScenario005() {
        var policy = SilencePolicy()
        let start = ContinuousClock.now
        _ = policy.observe(peak: loud, at: start)
        // A plausible noise floor still counts as quiet.
        XCTAssertFalse(policy.observe(peak: 0.015, at: at(0.5, from: start)))
        XCTAssertTrue(policy.observe(peak: 0.015, at: at(3.0, from: start)))
    }
}
