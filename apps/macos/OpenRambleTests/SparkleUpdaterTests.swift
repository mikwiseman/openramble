import XCTest

/// Updates are the second and last place the product goes online.
@MainActor
final class SparkleUpdaterTests: XCTestCase {
    /// There is no public key signature in the test bundle - this is exactly the case, for the sake of
    /// which the check was written.
    ///
    /// Sparkle's own check is leaky here: with an HTTPS feed address and
    /// signed application, it ignores the absence of a key and starts,
    /// leaving updates to the code signature alone. You can't be silent about this:
    /// the person will assume that updates are coming.
    func testScenario001() throws {
        let updater = SparkleUpdater()

        let failure = try XCTUnwrap(
            updater.startupFailure,
            "without a signature key, updates must refuse out loud, not silently weaken"
        )
        XCTAssertTrue(failure.contains("SUPublicEDKey"), "'\(failure)' does not say what is missing")
        XCTAssertTrue(failure.contains("Updates are disabled"))
    }
}
