import AppKit
import DictationCore
import SwiftUI

/// Termination hook.
///
/// SwiftUI's `App` has no "about to quit" callback, and the engine must be
/// released before the process exits — the inference runtime tears its Metal
/// device down from a static destructor, and doing that with a model still
/// loaded aborts instead of exiting.
private final class TerminationObserver: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        state?.releaseEngineBeforeTermination()
    }
}

@main
struct OpenRambleApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(TerminationObserver.self) private var termination
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // The adaptor creates the delegate before any scene exists, so it
        // cannot be handed the state at construction.
        let _ = { termination.state = state }()

        // The application lives in the menu bar: dictation does not have its own
        // window, it works on top of where the user is now.
        MenuBarExtra {
            MenuContent(
                state: state,
                showOnboarding: { onboardingCompleted = false }
            )
        } label: {
            // The brand mark is permanent. A small dot over its corner carries
            // the temporary states: red while recording, blue while working on
            // speech, orange when something waits for the person.
            MenuBarLabel(
                state: state.dictationState,
                isDictationReady: state.isDictationReady,
                hasRecoveredWork: state.recoveredText != nil,
                setupNeedsAttention: MenuBarStatus.setupNeedsUserAction(
                    accessibilityState: state.accessibilityState,
                    microphoneGranted: state.microphoneGranted,
                    modelState: state.modelState
                )
            )
            .task {
                // The first launch must show the setup itself. Without this
                // the application silently goes to the menu bar: there is no
                // icon in the dock, there is no window, and the person who
                // just dragged the app out of the image sees nothing at all —
                // neither permissions nor the model, without which dictation
                // does not work.
                guard !onboardingCompleted else { return }
                openWindow(id: "onboarding")
                WindowFronting.raiseOpenedWindow()
            }
        }

        // The content here is unconditional. While it was hiding behind
        // `if !onboardingCompleted`, macOS kept the scene itself: after
        // setup the "Window" menu had a "Welcome" item that opened a 0x0
        // frame without content. Now the same item honestly shows setup
        // again, exactly like "Finish Setting Up…" in the menu bar.
        Window("Welcome", id: "onboarding") {
            OnboardingView(state: state) { onboardingCompleted = true }
        }
        .windowResizability(.contentSize)
        // No title bar strip: the first-run wizard has neither a document nor
        // a name worth showing — only content.
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(state: state)
        }
    }
}
