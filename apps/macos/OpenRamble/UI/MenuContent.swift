import AppKit
import DictationCore
import SwiftUI

/// Menu in the menu bar - the entire application interface at rest.
///
/// Lies separately from the entry point intentionally: `OpenRambleApp.swift` does not
/// is compiled into a test target (there is `@main`), and everything that a person sees here is
/// must be checked.
struct MenuContent: View {
    @ObservedObject var state: AppState
    let showOnboarding: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showDeleteTextConfirmation = false
    @State private var showDeleteRecordingConfirmation = false

    var body: some View {
        Text(
            MenuBarStatus.statusLine(
                state: state.dictationState,
                isDictationReady: state.isDictationReady,
                isHandsFreeActive: state.isHandsFreeActive,
                hotkeyTitle: state.hotkey.title,
                hasRecoveredText: state.recoveredText != nil,
                hasRecoveredRecording: state.recoveredRecording != nil
            )
        )

        if state.dictationState == .preparing || state.dictationState == .listening {
            Divider()
            Button("Stop and insert") { state.finishCurrentDictation() }
            Button("Cancel and delete recording", role: .destructive) {
                state.cancelCurrentDictation()
            }
        }

        if !state.isDictationReady {
            Divider()
            setupHints
            Button("Run setup again") {
                showOnboarding()
                openWindow(id: "onboarding")
            }
        }

        if !state.recentDictations.isEmpty {
            Divider()
            Menu("Recent Dictations") {
                ForEach(state.recentDictations) { dictation in
                    Button(dictation.menuTitle) {
                        state.copyRecentDictation(dictation)
                    }
                }
            }
        }

        if state.canCopyRawDictation {
            Button("Copy last dictation verbatim") {
                state.copyRawDictation()
            }
        }

        if state.recoveredText != nil {
            Divider()
            // The title above the buttons is the same as the block with the entry below. Without him three
            // the buttons in a row do not say what they belong to, but the panel with
            // the explanation has long since left the screen by this point.
            Text("Uninserted text")
            Button("Retry insert") { state.retryRecoveredText() }
                .disabled(state.dictationState != .idle)
                .accessibilityHint(
                    state.dictationState == .idle
                        ? "Attempts to insert the saved text into the current field"
                        : "Finish or cancel the current dictation first"
                )
            Button("Copy text") { state.copyRecoveredText() }
            Button("Delete saved text", role: .destructive) {
                showDeleteTextConfirmation = true
            }
            .confirmationDialog(
                "Delete the only saved copy of this text?",
                isPresented: $showDeleteTextConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete saved text", role: .destructive) {
                    state.deleteRecoveredText()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Copy the text first if you may need it.")
            }
        }

        if state.recoveredRecording != nil {
            Divider()
            Text("Local recording after a failure")
            Button("Retry transcription") { state.retryRecoveredRecording() }
                .disabled(!state.modelState.isReady || state.dictationState != .idle)
            Button("Delete recording", role: .destructive) {
                showDeleteRecordingConfirmation = true
            }
            .confirmationDialog(
                "Delete the only saved copy of this recording?",
                isPresented: $showDeleteRecordingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete recording", role: .destructive) {
                    state.deleteRecoveredRecording()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Retry transcription first if you may need the dictation.")
            }
        }

        Divider()

        Button("Settings…") {
            openSettings()
            // Without this the window opens behind whatever the person was
            // working in: the app has no Dock icon (LSUIElement), so macOS does
            // not bring it forward on its own, and they have to hide other apps
            // to find the settings they just asked for.
            NSApp.activate(ignoringOtherApps: true)
        }
            .keyboardShortcut(",", modifiers: .command)

        Button("Quit OpenRamble") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var setupHints: some View {
        if !state.accessibilityGranted {
            switch state.accessibilityState {
            case .denied:
                Button("Grant Accessibility access") { state.requestAccessibility() }
            case .waitingForSettings:
                Button("Open Accessibility settings") { state.openAccessibilitySettings() }
            case .restartRequired:
                Button("Relaunch to apply access") { state.restartForAccessibility() }
            case .repairRequired, .failed:
                Text("Accessibility access needs repair")
            case .repairing:
                Text("Repairing Accessibility access…")
            case .granted:
                EmptyView()
            }
        }
        if !state.microphoneGranted {
            Button("Allow microphone") { state.requestMicrophone() }
        }
        // Via the same type as both screens. Previously, the menu knew about model one
        // boolean “ready or not” and suggested “Download” even in the middle of downloading -
        // the click went to nowhere, and the first line of the menu said
        // “Need setup”, without even mentioning that the download is in progress.
        // The volume is transferred, not taken by default. Without it the button in the menu
        // always promised 586 MB - a full installation - even when you need to download more
        // one hint for ~103 MB. This figure is used to decide whether to go ahead with the road.
        // or a slow network, and it is impossible to make mistakes in it five times.
        let model = ModelStatus.make(
            state: state.modelState,
            isPreparingEngine: state.isPreparingEngine,
            preparation: state.enginePreparation,
            place: .settings,
            downloadMegabytes: state.remainingDownloadMegabytes
        )
        if state.modelState.isReady, !state.isEngineReady {
            Text("Preparing the model for dictation…")
        } else if !state.modelState.isReady {
            Text(model.progressLabel.map { "\(model.title) — \($0)" } ?? model.title)

            ForEach(model.actions.filter { $0 != .delete }, id: \.self) { action in
                Button(model.title(for: action)) {
                    switch action {
                    case .install, .retry, .repair: state.installModel()
                    case .cancel: state.cancelModelInstall()
                    case .delete: break
                    }
                }
            }
        }
    }
}
