import XCTest

/// A window opened from the menu bar must end up in front of everything —
/// and the retry that gets it there must always stop.
@MainActor
final class WindowRaiserTests: XCTestCase {
    private final class FakeWindow: Raisable {
        let isRaisableWindow: Bool
        private(set) var raises = 0

        init(raisable: Bool) {
            self.isRaisableWindow = raisable
        }

        func raiseToFront() { raises += 1 }
    }

    /// The dictation panel is a borderless non-activating panel: it must never
    /// be dragged into focus by someone opening Settings.
    func testOnlyMainCapableWindowsAreRaised() {
        let panel = FakeWindow(raisable: false)
        let settings = FakeWindow(raisable: true)

        let step = WindowRaiser.step(windows: [panel, settings], attempt: 0)

        XCTAssertEqual(step, .raised)
        XCTAssertEqual(settings.raises, 1)
        XCTAssertEqual(panel.raises, 0, "the dictation panel is not a window to focus")
    }

    /// Settings opened while onboarding is up: both stay reachable.
    func testEveryEligibleWindowComesForward() {
        let onboarding = FakeWindow(raisable: true)
        let settings = FakeWindow(raisable: true)

        XCTAssertEqual(WindowRaiser.step(windows: [onboarding, settings], attempt: 0), .raised)
        XCTAssertEqual(onboarding.raises, 1)
        XCTAssertEqual(settings.raises, 1)
    }

    /// SwiftUI creates the window after the menu action returns, so the first
    /// look normally finds nothing. That is not a failure — look again.
    func testMissingWindowAsksForAnotherTurn() {
        XCTAssertEqual(
            WindowRaiser.step(windows: [FakeWindow(raisable: false)], attempt: 0),
            .retry
        )
    }

    /// A window that never appears must not leave anything looking forever.
    func testAttemptsAreBounded() {
        let last = WindowRaiser.maximumAttempts - 1
        XCTAssertEqual(WindowRaiser.step(windows: [], attempt: last - 1), .retry)
        XCTAssertEqual(WindowRaiser.step(windows: [], attempt: last), .giveUp)
    }
}
