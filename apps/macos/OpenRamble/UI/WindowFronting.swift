import AppKit

/// Bring a just-opened window in front of every other application.
///
/// OpenRamble has no Dock icon (`LSUIElement`), so macOS never raises its
/// windows on its own. `NSApp.activate()` alone is not enough either: SwiftUI
/// creates the Settings window *after* the menu action returns, so activation
/// lands on an app that has no window yet, and the window then appears
/// wherever the window server put it — behind the editor the person was just
/// working in. They then have to hunt for the window they just opened.
///
/// So the raise has to wait for the window to exist. That waiting is the whole
/// logic here, and `WindowRaiserTests` pins it through `Raisable`.
@MainActor
protocol Raisable {
    /// Whether this window is one the person should be looking at.
    ///
    /// Not matched by title: the Settings window renames itself after the
    /// selected tab ("General", "About", …), so a title would go stale the
    /// moment someone switches tabs. Main-capable is the honest criterion —
    /// the dictation panel is a borderless non-activating `NSPanel` and can
    /// never become main, so it is excluded by construction.
    var isRaisableWindow: Bool { get }
    /// Put it in front and make it key, even while the app is still inactive.
    func raiseToFront()
}

extension NSWindow: Raisable {
    var isRaisableWindow: Bool { canBecomeMain && isVisible }

    func raiseToFront() {
        // `orderFrontRegardless` is the part that works from an accessory app
        // whose activation may still be a moment away.
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
    }
}

/// Look for the window over a few run-loop turns, then raise it exactly once.
@MainActor
enum WindowRaiser {
    /// How many turns to look before giving up. Far longer than SwiftUI needs;
    /// the cap exists so a window that never appears cannot leave anything
    /// looking forever — "nothing ticks at rest" applies here too.
    static let maximumAttempts = 10

    enum Step: Equatable {
        /// Found and raised — stop.
        case raised
        /// Not there yet — look again on the next turn.
        case retry
        /// Out of attempts. Nothing raised, nothing left running.
        case giveUp
    }

    /// One attempt. Pure, so the rule is testable without a window server.
    @discardableResult
    static func step(
        windows: [any Raisable],
        attempt: Int,
        maximumAttempts: Int = maximumAttempts
    ) -> Step {
        let raisable = windows.filter(\.isRaisableWindow)
        guard raisable.isEmpty else {
            // Every eligible window comes forward: opening Settings while the
            // onboarding window is up should leave both reachable, not bury
            // one behind the app the person came from.
            raisable.forEach { $0.raiseToFront() }
            return .raised
        }
        return attempt + 1 < maximumAttempts ? .retry : .giveUp
    }
}

@MainActor
enum WindowFronting {
    /// Bring OpenRamble's windows forward as soon as one exists.
    ///
    /// The app is activated on every attempt, not only on success: a person
    /// who clicked a menu item expects OpenRamble to be the front app even in
    /// the fraction of a second before its window materializes.
    static func raiseOpenedWindow(attempt: Int = 0) {
        NSApp.activate()

        switch WindowRaiser.step(windows: NSApp.windows, attempt: attempt) {
        case .raised, .giveUp:
            return
        case .retry:
            // The next run-loop turn, not a timer: SwiftUI creates the window
            // within the same cycle, and a repeating timer would outlive the
            // reason it exists.
            DispatchQueue.main.async {
                raiseOpenedWindow(attempt: attempt + 1)
            }
        }
    }
}
