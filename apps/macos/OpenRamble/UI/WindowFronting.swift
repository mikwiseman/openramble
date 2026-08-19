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

    /// Which policy suits this set of windows.
    ///
    /// Pure, and separate from the raise, because it answers a question asked
    /// at two different moments: when a window opens and when one closes.
    static func policy(for windows: [any Raisable]) -> NSApplication.ActivationPolicy {
        windows.contains(where: \.isRaisableWindow) ? .regular : .accessory
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
    /// Live only while the app is a regular one, so the observer costs nothing
    /// in the state the app spends nearly all its time in.
    private static var closeObserver: (any NSObjectProtocol)?

    /// Watch for the last window closing, and go back to the menu bar.
    ///
    /// Registered on the way up rather than at launch: an app that has never
    /// opened a window has nothing to observe, and "nothing ticks at rest"
    /// holds here as everywhere else.
    private static func observeWindowClosing() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            // The closing window is still in `NSApp.windows` and still reports
            // itself visible, so it has to be excluded by hand — otherwise the
            // app would stay in the Dock after its last window is gone.
            //
            // Read here, on the notification's own queue (`.main`), so nothing
            // of the notification crosses into the task below.
            let closing = notification.object as? NSWindow
            Task { @MainActor in
                let remaining = NSApp.windows.filter { $0 !== closing }
                returnToMenuBar(ifNoWindowsAmong: remaining)
            }
        }
    }

    /// Drop the Dock icon once nothing is left to look at.
    static func returnToMenuBar(ifNoWindowsAmong windows: [any Raisable]) {
        guard WindowRaiser.policy(for: windows) == .accessory else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Bring OpenRamble's windows forward as soon as one exists.
    ///
    /// The app is activated on every attempt, not only on success: a person
    /// who clicked a menu item expects OpenRamble to be the front app even in
    /// the fraction of a second before its window materializes.
    static func raiseOpenedWindow(attempt: Int = 0) {
        // The policy change is the part that works, and it is not decoration.
        //
        // Activation on macOS is cooperative: `activate` *asks* the app in
        // front to yield, and an accessory app — one with no Dock icon — is
        // not granted the front. Measured on macOS 26 with Settings already
        // open behind a browser: clicking Settings again left the window
        // *below* the browser whether activation passed `ignoringOtherApps` or
        // not, and whether it was retried on later run-loop turns or not. That
        // is the "I have to hide other windows to find it" report, reproduced.
        //
        // A regular app is granted the front. So the app becomes one for
        // exactly as long as it has a window worth looking at, and drops back
        // to the menu bar when the last one closes — see `returnToMenuBar`.
        // The Dock icon appearing alongside a visible window is what every
        // other Mac app does; a Dock icon with nothing behind it is what this
        // app still refuses.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        observeWindowClosing()

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
