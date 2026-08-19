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

    /// The Dock icon is the price of being allowed to come to the front, and
    /// it lasts exactly as long as there is a window to go with it.
    ///
    /// Measured on macOS 26: an accessory app is not granted activation, and
    /// its Settings window stays behind whatever the person was working in —
    /// no matter what is passed to `activate` or how often it is retried. A
    /// regular app is granted it. So the policy follows the windows.
    func testTheAppIsARegularOneOnlyWhileItHasAWindow() {
        let panel = FakeWindow(raisable: false)
        let settings = FakeWindow(raisable: true)

        XCTAssertEqual(WindowRaiser.policy(for: [settings]), .regular)
        XCTAssertEqual(WindowRaiser.policy(for: [panel, settings]), .regular)
        // The dictation panel is not a window to have a Dock icon for: it is
        // shown during dictation, which is every day, and a Dock icon that
        // blinks on every phrase is worse than none.
        XCTAssertEqual(WindowRaiser.policy(for: [panel]), .accessory)
        XCTAssertEqual(WindowRaiser.policy(for: []), .accessory)
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
