import AppKit
import DictationCore
import SwiftUI

@main
struct OpenRambleApp: App {
    @StateObject private var state = AppState()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // The application lives in the menu bar: dictation does not have its own window, it
        // works on top of where the user is now.
        MenuBarExtra {
            MenuContent(
                state: state,
                showOnboarding: { onboardingCompleted = false }
            )
        } label: {
            // The brand remains stable. A small status dot carries the temporary
            // recording, processing and successful-insertion states.
            MenuBarLabel(
                state: state.dictationState,
                isDictationReady: state.isDictationReady,
                hasRecoveredWork: state.recoveredText != nil
                    || state.recoveredRecording != nil
            )
            .task {
                // The first launch must show the setting itself. Without this
                // the application silently goes to the menu bar: there is no icon in the dock,
                // there is no window, and the person who just dragged it out
                // image, does not see anything at all - neither permissions, nor model,
                // without which dictation does not work.
                guard !onboardingCompleted else { return }
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // The content here is unconditional. While it was hiding behind
        // `if !onboardingCompleted`, macOS kept the scene itself: after
        // settings in the “Window” menu there was a “Welcome” item, and it opened a window
        // size 0x0 - a frame without content, from which there is nothing to close and
        // it’s not clear what it was. Now the same point honestly shows
        // setup again, exactly like “Run setup again” in the menu bar.
        Window("Welcome", id: "onboarding") {
            OnboardingView(state: state) { onboardingCompleted = true }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(state: state)
        }
    }
}
