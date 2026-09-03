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

    /// Quitting mid-recording is the one place a dialog is right: it is the
    /// only irreversible act in the feature. The recording is filed before
    /// AppKit gets its reply.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.isRecordingInProgress else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop recording and quit?"
        alert.informativeText = "Everything recorded so far will be kept."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        state.stopRecordingBeforeTermination()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.releaseEngineBeforeTermination()
    }
}

@main
struct OpenRambleApp: App {
    static let settingsWindowID = "settings"

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
        // Shown unless the person moved the app to the Dock alone. There is no
        // choice that hides both — see `AppPresence`.
        MenuBarExtra(isInserted: .constant(state.presence.showsMenuBarIcon)) {
            MenuContent(
                state: state,
                showOnboarding: { onboardingCompleted = false }
            )
            // The chosen look has to be applied to AppKit, and the menu is the
            // one piece of this app that exists from launch — every window
            // here is opened later, or never.
            .task {
                AppState.apply(state.appearance)
                AppState.applyDockPresence(state.presence)
                // Closing the settings window must not take away a Dock icon
                // the person asked to keep.
                WindowFronting.onWindowsClosed = { [weak state] in
                    (state?.presence.showsDockIcon ?? false) ? .regular : .accessory
                }
            }
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
                ),
                isRecordingMeeting: state.meetingState == .recording,
                recordingIsDegraded: state.liveCaptureHealth.marksRecordingDegraded
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

        // A plain window rather than the `Settings` scene.
        //
        // The Settings scene brings its own chrome, and on macOS 26 that chrome
        // fights a `NavigationSplitView`: the sidebar renders as an inset panel
        // whose border passes directly under the close button, and the content
        // scrolls up behind a title bar that reserved no room for it. Both are
        // visible in a screenshot and neither is anything the view itself asks
        // for. A `Window` gets the ordinary titlebar every other Mac app has,
        // which is all the sidebar ever needed.
        // The library. A `Window` for the same reason Settings is one, sized
        // for content that is unbounded: a person decides how much of a
        // transcript to look at, not the window.
        Window("Recordings", id: RecordingsWindow.windowID) {
            RecordingsWindow(state: state)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Recordings…") {
                    openWindow(id: RecordingsWindow.windowID)
                    WindowFronting.raiseOpenedWindow()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Window("Settings", id: Self.settingsWindowID) {
            SettingsView(state: state)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 780, height: 580)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openWindow(id: Self.settingsWindowID) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
