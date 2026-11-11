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
        let sections = MenuSections.sections(for: state)

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
                    waitingReason: state.waitingWords?.reason(key: state.hotkey.shortTitle)
                )
            )

        case .stopAndInsert:
            Button(L10n.tr("Stop and Insert")) { state.finishCurrentDictation() }

        case .cancelDictation:
            Button(L10n.tr("Cancel Dictation"), role: .destructive) {
                state.cancelCurrentDictation()
            }

        case .setupHints:
            setupHints

        case .finishSetup:
            Button(L10n.tr("Finish Setting Up…")) {
                showOnboarding()
                openWindow(id: "onboarding")
                // Activation alone is not enough — the window does not exist
                // yet at this point and would open behind whatever the person
                // was working in. See `WindowFronting`.
                WindowFronting.raiseOpenedWindow(id: "onboarding")
            }

        case let .take(index):
            let takes = state.menuTakes
            if takes.indices.contains(index) {
                let words = Self.firstWords(of: takes[index])
                // The words themselves are the row. A click pastes them where
                // the person is; with Option held the row reads Copy and
                // copies. Only the first carries the chord: it is the last
                // take, the one the chord pastes.
                Button {
                    // Before macOS 15 a menu row cannot change while Option
                    // is held, so the click itself is asked.
                    if NSEvent.modifierFlags.contains(.option) {
                        state.copyTake(at: index)
                    } else {
                        state.pasteTake(at: index)
                    }
                } label: {
                    Text(L10n.tr("“%@”", words))
                }
                .shortcutColumn(index == 0 ? state.lastTakeShortcut : nil)
                .optionAlternate {
                    Button(L10n.tr("Copy “%@”", words)) { state.copyTake(at: index) }
                }
                .disabled(state.dictationState != .idle)
                .accessibilityLabel(L10n.tr("Paste “%@”", words))
                .accessibilityHint(
                    state.dictationState == .idle
                        ? L10n.tr("Pastes these words into the app in front. Hold Option to copy them instead.")
                        : L10n.tr("Finish or cancel the current dictation first")
                )
            }

        case .revealRecoveredRecordings:
            Button(
                state.recordingRecoveryStorageFaulted
                    ? L10n.tr("Recording Support Files — Recovery Disabled…")
                    : L10n.tr("Recovered Recordings (%@)…", String(describing: state.recoveredRecordingCount))
            ) {
                state.revealRecoveredRecordings()
            }

        case .recordingLine:
            switch state.meetingState {
            case .starting: Text(L10n.tr("Starting recording…"))
            case .stopping: Text(L10n.tr("Saving recording…"))
            case .idle, .recording, .paused:
                Text(MenuBarStatus.recordingLine(
                    isPaused: state.meetingState == .paused,
                    duration: state.liveDuration,
                    isDegraded: state.liveCaptureHealth.marksRecordingDegraded,
                    microphoneMissing: state.liveMicrophoneHealth.marksRecordingDegraded
                ))
            }

        case .startRecording:
            Button(L10n.tr("Start Recording")) { state.startRecording() }
            .shortcutColumn(state.recordingShortcut)
            .accessibilityHint(
                state.systemAudioMode == .enabled
                    ? L10n.tr("Records you and the other side until you stop")
                    : L10n.tr("Records your microphone until you stop")
            )

        case .startScreenRecording:
            Button(L10n.tr("Record Screen…")) {
                openWindow(id: RecordingsWindow.windowID)
                WindowFronting.raiseOpenedWindow(id: RecordingsWindow.windowID)
                state.prepareScreenRecording()
            }
            .shortcutColumn(state.screenRecordingShortcut)
            .accessibilityHint(L10n.tr("Opens screen recording choices"))

        case .pauseRecording:
            Button(L10n.tr("Pause Recording")) { state.pauseRecording() }

        case .resumeRecording:
            Button(L10n.tr("Resume Recording")) { state.resumeRecording() }

        case .stopRecording:
            Button(L10n.tr("Stop Recording")) { state.stopRecording() }
            .shortcutColumn(state.recordingShortcut)
            .accessibilityHint(L10n.tr("Ends the recording and keeps it"))

        case .openRecordings:
            Button(L10n.tr("Library…")) {
                openWindow(id: RecordingsWindow.windowID)
                WindowFronting.raiseOpenedWindow(id: RecordingsWindow.windowID)
            }
            // No shortcut here or on the two rows below. A shortcut printed in
            // this menu is one that works from any app, and ⌘R, ⌘, and ⌘Q
            // work only while an OpenRamble window is in front, where ⌘, and
            // ⌘Q still do.

        case .settings:
            Button(L10n.tr("Settings…")) {
                openWindow(id: "settings")
                // The Settings window is created after this action returns, so
                // it has to be raised once it exists. See `WindowFronting`.
                WindowFronting.raiseOpenedWindow(id: "settings")
            }

        case .quit:
            Button(L10n.tr("Quit OpenRamble")) { NSApplication.shared.terminate(nil) }
        }
    }

    /// The take's first words on one line, short enough for a menu.
    static func firstWords(of text: String) -> String {
        let singleLine = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard singleLine.count > 44 else { return singleLine }
        return String(singleLine.prefix(43)) + "…"
    }


    @ViewBuilder
    private var setupHints: some View {
        if !state.accessibilityGranted {
            switch state.accessibilityState {
            case .denied:
                Button(L10n.tr("Grant Accessibility Access")) { state.requestAccessibility() }
            case .waitingForSettings:
                Button(L10n.tr("Open Accessibility Settings")) { state.openAccessibilitySettings() }
            case .failed:
                Text(L10n.tr("Accessibility access needs repair"))
            case .repairing:
                Text(L10n.tr("Repairing Accessibility access…"))
            case .granted:
                EmptyView()
            }
        }
        if !state.microphoneGranted {
            Button(L10n.tr("Allow Microphone")) { state.requestMicrophone() }
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
                    case .delete, .keyboardSettings: break
                    }
                }
            }
        }
    }
}

extension View {
    /// Show a global shortcut where a menu shows shortcuts: in its own
    /// column, right-aligned and dimmed.
    ///
    /// The chord itself is a Carbon hot key and works from any app. This
    /// only prints it, and lets the same keys work while the menu is open.
    /// A chord the menu cannot print leaves the row without one; Settings
    /// still shows it.
    @ViewBuilder
    func shortcutColumn(_ shortcut: KeyCombination?) -> some View {
        if let key = shortcut?.menuShortcut {
            keyboardShortcut(key)
        } else {
            self
        }
    }

    /// What the row becomes while Option is held. Before macOS 15 a menu row
    /// has no alternate, and the row's own action asks for the modifier.
    @ViewBuilder
    func optionAlternate<Alternate: View>(@ViewBuilder _ alternate: () -> Alternate) -> some View {
        if #available(macOS 15.0, *) {
            modifierKeyAlternate(.option, alternate)
        } else {
            self
        }
    }
}

extension MenuSections {
    /// The rows for the app as it is now: the one place the menu reads its
    /// inputs, so a test can check the real wiring.
    @MainActor
    static func sections(for state: AppState) -> [[MenuRow]] {
        sections(
            state: state.dictationState,
            isDictationReady: state.isDictationReady,
            wordsAreWaiting: state.waitingWords != nil,
            recoveryStorageFaulted: state.recordingRecoveryStorageFaulted,
            takes: state.menuTakes.count,
            recordingState: state.meetingState
        )
    }
}
