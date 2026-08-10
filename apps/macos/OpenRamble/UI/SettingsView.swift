import DictationCore
import LocalASR
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettings(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings(state: state)
                .tabItem { Label("Model", systemImage: "waveform") }
            DictionarySettings(state: state)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            // Updates are the only thing the application does online without
            // direct command, and previously this switch was the fifth section
            // "General": in a window 400 pixels high, it would appear below the fold, and
            // the person who came to the settings specifically for him saw a page without
            //him. A separate tab puts it where people are looking for it.
            UpdateSettings(updater: state.updater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Main

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @State private var showAccessibilityRepairConfirmation = false

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $state.hotkey) {
                    ForEach(DictationHotkey.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                    }
                }
                .accessibilityHint("The key you hold down while dictating")

                Text("Hold the key and speak. Double-press to dictate without holding — recording then stops on the next press.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = state.hotkeyWarning {
                    // Fn is the only key in the list that has its own
                    // system purpose and which may not be on the external
                    // keyboard. To remain silent about this means to abandon a person
                    // find out for yourself why dictation “sometimes doesn’t work.”
                    Label {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Key warning. \(warning)")
                }
            }

            Section {
                // Autorun was written and worked, but it was impossible to enable it
                // nowhere: hotkey utility, not survived
                // reboot, indistinguishable from a broken one - the key is just
                // is silent, and there is no one to explain it to.
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                    .accessibilityHint("Starts OpenRamble automatically when you log in")
                Text("A dictation key only works while the app is running. Without this, the key stops working after every restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sounds when recording starts and stops", isOn: $state.soundsEnabled)
                    .accessibilityHint("A short tone when recording starts and when it stops")

                // The preview is described in the code as a decoration that can be
                // turn it off - but there was no switch.
                Toggle("Show recognized words while you speak", isOn: $state.showLivePreview)
                    .accessibilityHint("Shows the text being recognized inside the dictation panel")
                Text("The dictation panel shows the text as it is recognized. Turn this off if you'd rather not see it on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show how long it took", isOn: $state.showSpeedReadout)
                    .accessibilityHint("Shows the time from releasing the key to the text appearing")
                Text("After each dictation the panel briefly shows the time from releasing the key to the text landing in your app. Measured, not estimated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // The only place where the application reads the content of someone else's
                // windows. Off by default, and the caption says exactly that
                // exactly read - otherwise the choice is not conscious.
                Toggle("Learn from your edits", isOn: $state.learnFromEdits)
                    .accessibilityHint("Reads back the field it pasted into, to learn words you fix by hand")
                Text("After pasting, OpenRamble re-reads that one text field twice — at 8 and 25 seconds — to see whether you corrected a word, and adds the pair to your dictionary. It reads only the field it pasted into, only in that window, and nothing leaves your Mac. Off by default: this is the one thing the app reads inside another app's window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Recognition language", selection: $state.recognitionLanguage) {
                    Text("Automatic — recommended").tag(String?.none)
                    ForEach(RecognitionLanguages.options) { option in
                        Text(option.name).tag(String?.some(option.code))
                    }
                }
                .accessibilityHint("Language the engine listens for; Automatic detects it from your voice")
                Text("Automatic detects the language from your voice, including mixed phrases. Pick a specific language only when detection keeps guessing wrong — it narrows recognition to that language alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text insertion") {
                Text("OpenRamble briefly uses the clipboard to paste, then restores its previous contents in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                PermissionRow(
                    status: PermissionStatus.accessibility(
                        state: state.accessibilityState,
                        detail: "Needed to hear the hotkey and insert text.",
                    ),
                    action: performAccessibilityAction
                )
                if needsAccessibilityRepair {
                    HStack {
                        Button("Show in Finder") {
                            state.revealApplicationForAccessibility()
                        }
                        Button("Open System Settings") {
                            state.openAccessibilitySettings()
                        }
                    }
                }
                PermissionRow(
                    status: PermissionStatus(
                        title: "Microphone",
                        detail: "Needed to record your speech.",
                        granted: state.microphoneGranted
                    ),
                    action: state.requestMicrophone
                )
            }
        }
        .formStyle(.grouped)
        // Permissions are granted in system settings, and returned here
        // a person should see a fresh state, and not what was before leaving.
        .task { state.refreshPermissions() }
        .confirmationDialog(
            "Repair Accessibility access?",
            isPresented: $showAccessibilityRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset OpenRamble's access and relaunch", role: .destructive) {
                state.repairAccessibility()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will remove only OpenRamble's Accessibility entries. After the relaunch you will need to grant access again.")
        }
    }

    private var needsAccessibilityRepair: Bool {
        switch state.accessibilityState {
        case .repairRequired, .failed:
            true
        default:
            false
        }
    }

    private func performAccessibilityAction() {
        switch state.accessibilityState {
        case .denied:
            state.requestAccessibility()
        case .waitingForSettings:
            state.openAccessibilitySettings()
        case .restartRequired:
            state.restartForAccessibility()
        case .repairRequired, .failed:
            showAccessibilityRepairConfirmation = true
        case .repairing, .granted:
            break
        }
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    // Sparkle reports its changes itself; they would not have reached through AppState.
    @ObservedObject var updater: SparkleUpdater

    var body: some View {
        Form {
            Section {
                // The switch goes out along with the update mechanism. Otherwise
                // it turned out to be a silent lie: next to it it says “no updates
                // work”, the person clicks the switch, the text below it
                // promises daily checks - and the setup goes into
                // the mechanism is not running and does nothing.
                Toggle("Check for updates automatically", isOn: $updater.automaticChecksEnabled)
                    .accessibilityHint("The only switch that changes the app's network behavior")
                    .disabled(updater.startupFailure != nil)
                Text("Off by default. When on, the app downloads a small version list from GitHub once a day. Apart from the model download and the update itself, there are no other network requests: only your IP address and the app version are sent — no details about your computer, and nothing you dictated.")
                    .font(.caption)
                    .foregroundStyle(updater.startupFailure == nil ? .secondary : .tertiary)

                HStack {
                    Button("Check now", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                    Spacer()
                }
            }

            if let failure = updater.startupFailure {
                Section {
                    // You can’t be silent: otherwise a person will think that
                    // updates come, but they don't arrive.
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Updates are not working", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Updates are not working. \(failure)")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityValue(status.accessibilityValue)

            Spacer()
            if let title = status.actionTitle {
                Button(title, action: action)
                    .accessibilityLabel(status.actionAccessibilityLabel ?? title)
            } else {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    // The checkmark has already been read as a string value: second time
                    // “issued” without an owner only gets in the way.
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Model

private struct ModelSettings: View {
    @ObservedObject var state: AppState
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            Section {
                ModelStatusView(
                    status: ModelStatus.make(
                        state: state.modelState,
                        isPreparingEngine: state.isPreparingEngine,
                        preparation: state.enginePreparation,
                        place: .settings,
                        downloadMegabytes: state.remainingDownloadMegabytes
                    ),
                    install: state.installModel,
                    cancel: state.cancelModelInstall,
                    // Delete is next to regular buttons and earlier
                    // worked on the first click: a miss cost half
                    // gigabyte and new download. There is nothing to cancel this, it means
                    // ask.
                    delete: { showDeleteConfirmation = true }
                )
            }

            Section {
                Text("Parakeet TDT 0.6B v3 is a multilingual recognition model that runs locally on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshModelState() }
        .confirmationDialog(
            "Delete the recognition model?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete model", role: .destructive) { state.deleteModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dictation stops working until you download the model again — that's another \(state.remainingDownloadMegabytes == 0 ? 586 : state.remainingDownloadMegabytes) MB over the network.")
        }
    }
}

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject var state: AppState
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Replacements apply to the recognized text. Useful for names the model hears differently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let problem = state.dictionaryProblem {
                    // The dictionary is write-locked. You have to say this
                    // here: the person stands exactly on the page where he is going
                    // edit it, and must find out before you start.
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Dictionary can't be edited", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                        Text(problem.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Dictionary can't be edited. \(problem.message)")
                }

            }
            .padding()

            // An empty dictionary is common for a new person, and it used to be
            // I saw in this place just a half-window gap without a single word.
            if state.replacements.isEmpty {
                VStack(spacing: 4) {
                    Text("No replacements yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Add a pair below: what the model hears on the left, what should be written on the right.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                List {
                    ForEach(state.replacements) { replacement in
                        HStack {
                            Text(replacement.spoken)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(replacement.written)
                            if replacement.noAcousticBoost {
                                Spacer(minLength: 8)
                                // The attribute is visible in the list, because otherwise it
                                // inexplicable: the person marked the term, nothing
                                // has changed in appearance, and the sign is forgotten.
                                Text("text only")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        // The entire line is read: "sentry", arrow and "Sentry"
                        // separately do not mean anything.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            replacement.noAcousticBoost
                                ? "Heard as “\(replacement.spoken)”, written as “\(replacement.written)”, text only — not used to help recognition"
                                : "Heard as “\(replacement.spoken)”, written as “\(replacement.written)”"
                        )
                    }
                    .onDelete(perform: state.removeReplacements)
                }
                .disabled(!state.isDictionaryEditable)
                .accessibilityLabel("Replacement list")
            }

            Divider()

            HStack {
                // Signature of the fields only in the form of a hint inside the frame: empty
                // VoiceOver will read the field, but the filled-in field will no longer be read, and the person
                // will lose which of the two fields it is in.
                TextField("Heard as", text: $spoken)
                    .accessibilityLabel("Heard as")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("Write as", text: $written)
                    .accessibilityLabel("Write as")
                Button("Add") {
                    state.addReplacement(spoken: spoken, written: written)
                    spoken = ""
                    written = ""
                }
                .disabled(spoken.isEmpty || written.isEmpty || !state.isDictionaryEditable)
                .accessibilityLabel("Add replacement")
                .accessibilityHint(
                    state.isDictionaryEditable
                        ? "Fill in both fields"
                        : "The dictionary can't be edited until the previous data has been read"
                )
            }
            .padding()
        }
    }
}

// MARK: - About the program

private struct AboutView: View {
    /// Version and build number. The first thing asked in any bug report is
    /// and the only place where this could be read is not in the application
    /// it was completely: there is no icon in the Dock, “About” from the main menu is unreachable.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(marketing) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenRamble")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Dictation that runs entirely on your Mac.")
                .foregroundStyle(.secondary)
            Text(version)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("What goes over the network")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("The model download you start yourself, and the update check if you turned it on. Nothing else: your speech, text, and keystrokes are never sent anywhere and never stored anywhere except your computer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Recognition models")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Parakeet TDT 0.6B v3 © NVIDIA, licensed under CC BY 4.0. Converted to Core ML and quantized with a 6-bit palette by the FluidInference project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Parakeet TDT-CTC 110M © NVIDIA, licensed under CC BY 4.0 — the acoustic vocabulary helper. Converted to Core ML by the FluidInference project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Libraries: FluidAudio (Apache 2.0), Sparkle (MIT).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
