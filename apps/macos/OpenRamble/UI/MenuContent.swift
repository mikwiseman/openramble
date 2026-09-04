import AppKit
import DictationCore
import SwiftUI

/// Menu in the menu bar — the entire application interface at rest.
///
/// Lives separately from the entry point intentionally: `OpenRambleApp.swift`
/// is not compiled into the test target (it holds `@main`), and everything a
/// person sees here must be checked.
///
/// Which rows appear when is decided by `MenuSections`, a pure type with its
/// own tests; this view only knows how each row looks and what it calls.
struct MenuContent: View {
    @ObservedObject var state: AppState
    let showOnboarding: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let sections = MenuSections.sections(
            state: state.dictationState,
            isDictationReady: state.isDictationReady,
            hasRecoveredText: state.recoveredText != nil,
            recoveryStorageFaulted: state.recordingRecoveryStorageFaulted,
            hasRecents: !state.recentDictations.isEmpty,
            isRecording: state.meetingState == .recording || state.meetingState == .paused
        )

        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(Array(section.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MenuRow) -> some View {
        switch row {
        case .statusLine:
            Text(
                MenuBarStatus.statusLine(
                    state: state.dictationState,
                    isDictationReady: state.isDictationReady,
                    isHandsFreeActive: state.isHandsFreeActive,
                    hotkeyTitle: state.hotkey.title,
                    hasRecoveredText: state.recoveredText != nil
                )
            )

        case .stopAndInsert:
            Button("Stop and Insert") { state.finishCurrentDictation() }

        case .cancelDictation:
            Button("Cancel Dictation", role: .destructive) {
                state.cancelCurrentDictation()
            }

        case .setupHints:
            setupHints

        case .finishSetup:
            Button("Finish Setting Up…") {
                showOnboarding()
                openWindow(id: "onboarding")
                // Activation alone is not enough — the window does not exist
                // yet at this point and would open behind whatever the person
                // was working in. See `WindowFronting`.
                WindowFronting.raiseOpenedWindow()
            }

        case .insertLastDictation:
            Button("Insert Last Dictation") { state.retryRecoveredText() }
                .disabled(state.dictationState != .idle)
                .accessibilityHint(
                    state.dictationState == .idle
                        ? "Attempts to insert the saved text into the current field"
                        : "Finish or cancel the current dictation first"
                )

        case .revealRecoveredRecordings:
            Button(
                state.recordingRecoveryStorageFaulted
                    ? "Recording Support Files — Recovery Disabled…"
                    : "Recovered Recordings (\(state.recoveredRecordingCount))…"
            ) {
                state.revealRecoveredRecordings()
            }

        case .recentDictations:
            Menu("Recent Dictations") {
                ForEach(Array(state.recentDictations.enumerated()), id: \.element.id) { index, dictation in
                    Button {
                        state.copyRecentDictation(dictation)
                    } label: {
                        // The copy key belongs on the first row, because the
                        // first row is the last dictation — the one the key
                        // copies. Written into the title rather than set as a
                        // real shortcut: this is a held modifier, and
                        // `keyboardShortcut` cannot express one.
                        Text(dictation.menuTitle)
                    }
                }
            }

        case .copyLast:
            // Its own row rather than a label inside the submenu. The menu
            // shows a shortcut beside Settings and Quit; the copy key was the
            // one binding with nowhere to be seen, because it lived a level
            // down next to a dictation rather than next to its own action.
            Button {
                state.copyLastDictation()
            } label: {
                // Written into the title: this can be a bare function key,
                // which `keyboardShortcut` cannot express.
                Text(titled("Copy Last Dictation", shortcut: state.copyShortcut))
            }


        case .recordingLine:
            Text(MenuBarStatus.recordingLine(
                isPaused: state.meetingState == .paused,
                duration: state.liveDuration,
                isDegraded: state.liveCaptureHealth.marksRecordingDegraded
            ))

        case .startRecording:
            Button {
                state.startRecording()
            } label: {
                Text(titled("Start Recording", shortcut: state.recordingShortcut))
            }
            .accessibilityHint("Records your microphone until you stop")

        case .stopRecording:
            Button {
                state.stopRecording()
            } label: {
                Text(titled("Stop Recording", shortcut: state.recordingShortcut))
            }
            .accessibilityHint("Ends the recording and keeps it")

        case .openRecordings:
            Button("Recordings…") {
                openWindow(id: RecordingsWindow.windowID)
                WindowFronting.raiseOpenedWindow()
            }
            .keyboardShortcut("0", modifiers: .command)

        case .settings:
            Button("Settings…") {
                openWindow(id: "settings")
                // The Settings window is created after this action returns, so
                // it has to be raised once it exists. See `WindowFronting`.
                WindowFronting.raiseOpenedWindow()
            }
            .keyboardShortcut(",", modifiers: .command)

        case .quit:
            Button("Quit OpenRamble") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    /// A held modifier cannot be a `keyboardShortcut`, and a function key
    /// cannot either. The title is the one place every binding can be seen.
    private func titled(_ name: String, shortcut: KeyCombination?) -> String {
        guard let shortcut else { return name }
        return "\(name)   \(shortcut.displayString)"
    }

    @ViewBuilder
    private var setupHints: some View {
        if !state.accessibilityGranted {
            switch state.accessibilityState {
            case .denied:
                Button("Grant Accessibility Access") { state.requestAccessibility() }
            case .waitingForSettings:
                Button("Open Accessibility Settings") { state.openAccessibilitySettings() }
            case .restartRequired:
                Button("Relaunch to Apply Access") { state.restartForAccessibility() }
            case .repairRequired, .failed:
                Text("Accessibility access needs repair")
            case .repairing:
                Text("Repairing Accessibility access…")
            case .granted:
                EmptyView()
            }
        }
        if !state.microphoneGranted {
            Button("Allow Microphone") { state.requestMicrophone() }
        }
        // Via the same type as both screens. Previously, the menu knew one
        // boolean about the model and suggested "Download" even mid-download —
        // the click went nowhere while the first line said "Setup needed"
        // without even mentioning the running download.
        // The remaining volume is passed in, not defaulted: the button must
        // name the actual download (~103 MB after an update), not always the
        // full 586 MB — people decide about hotel Wi-Fi with this number.
        let model = ModelStatus.make(
            state: state.modelState,
            preparation: state.enginePreparation,
            place: .settings,
            downloadMegabytes: state.remainingDownloadMegabytes,
            isEngineReady: state.isEngineReady,
            isPreparingEngine: state.isPreparingEngine
        )
        // What to say, and whether to say anything, is the card type's decision
        // — see `ModelStatus.setupLine`. The menu used to answer that question
        // a second time and reached a different answer than the card standing
        // next to it.
        if let line = model.setupLine {
            Text(line)

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
