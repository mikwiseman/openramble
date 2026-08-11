import AppKit
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
        .frame(width: 620, height: 500)
    }
}

// MARK: - Main

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @State private var showAccessibilityRepairConfirmation = false

    var body: some View {
        Form {
            Section("Shortcut") {
                Picker("Dictation key", selection: $state.hotkey) {
                    ForEach(DictationHotkey.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                    }
                }
                .accessibilityHint("The key you hold down while dictating")

                Text("Hold to talk, or double-press for hands-free dictation. Press once more to finish.")
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

            Section("Behavior") {
                // Autorun was written and worked, but it was impossible to enable it
                // nowhere: hotkey utility, not survived
                // reboot, indistinguishable from a broken one - the key is just
                // is silent, and there is no one to explain it to.
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                    .accessibilityHint("Starts OpenRamble automatically when you log in")
                Toggle("Play sounds when recording starts and stops", isOn: $state.soundsEnabled)
                    .accessibilityHint("A short tone when recording starts and when it stops")
            }

            Section("Private personalization") {
                // The only place where the application reads the content of someone else's
                // windows. Off by default, and the caption says exactly that
                // exactly read - otherwise the choice is not conscious.
                Toggle("Learn from your edits", isOn: $state.learnFromEdits)
                    .accessibilityHint("Reads back the field it pasted into, to learn words you fix by hand")
                Text("Off by default. After a paste, OpenRamble can re-read only that field at 8 and 25 seconds to learn a correction. The content stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recognition") {
                Picker("Recognition language", selection: $state.recognitionLanguage) {
                    Text("Automatic — recommended").tag(String?.none)
                    ForEach(RecognitionLanguages.options) { option in
                        Text(option.name).tag(String?.some(option.code))
                    }
                }
                .accessibilityHint("Language the engine listens for; Automatic detects it from your voice")
                Text("Automatic handles mixed-language speech. Choose one language only if detection repeatedly guesses wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions & insertion") {
                Text("Finished text is pasted through the clipboard; its previous contents are restored shortly afterward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section("Automatic checks") {
                // The switch goes out along with the update mechanism. Otherwise
                // it turned out to be a silent lie: next to it it says “no updates
                // work”, the person clicks the switch, the text below it
                // promises daily checks - and the setup goes into
                // the mechanism is not running and does nothing.
                Toggle("Check for updates automatically", isOn: $updater.automaticChecksEnabled)
                    .accessibilityHint("The only switch that changes the app's network behavior")
                    .disabled(updater.startupFailure != nil)
                Text("On by default so security fixes can reach you. Once a day, the app reads a small version list. The request contains the app version and your IP address, but no device profile or dictated content. Turn this off to stop scheduled network access.")
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
            Section("On-device recognition") {
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

            Section("Model details") {
                LabeledContent("Engine", value: "Parakeet TDT 0.6B v3")
                LabeledContent("Processing", value: "Entirely on this Mac")
                Text("Once downloaded and verified, recognition works offline. Audio is not uploaded.")
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
                Text("Common technical terms are handled automatically. Add personal names or phrases the model hears differently.")
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
                    Text("No personal replacements yet")
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

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Heard as")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Spoken phrase", text: $spoken)
                        .accessibilityLabel("Heard as")
                        .onSubmit(addReplacement)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                    .padding(.bottom, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Write as")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Final spelling", text: $written)
                        .accessibilityLabel("Write as")
                        .onSubmit(addReplacement)
                }
                Button("Add", action: addReplacement)
                    .disabled(!canAddReplacement)
                    .accessibilityLabel("Add replacement")
                    .accessibilityHint(addReplacementHint)
            }
            .padding()
        }
    }

    private var canAddReplacement: Bool {
        !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.isDictionaryEditable
    }

    private var addReplacementHint: String {
        if !state.isDictionaryEditable {
            return "The dictionary can't be edited until the previous data has been read"
        }
        return canAddReplacement
            ? "Adds this replacement to future dictations"
            : "Fill in both fields"
    }

    private func addReplacement() {
        guard canAddReplacement else { return }
        state.addReplacement(spoken: spoken, written: written)
        spoken = ""
        written = ""
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

    @State private var showsCredits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenRamble")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Private dictation for your Mac")
                        .foregroundStyle(.secondary)
                    Text(version)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Divider()

            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Speech stays on this Mac")
                        .font(.headline)
                    Text("No account, analytics, or cloud transcription. Network access is limited to model downloads and update checks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
            }
            .accessibilityElement(children: .combine)

            DisclosureGroup("Model and library credits", isExpanded: $showsCredits) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Parakeet TDT 0.6B v3 and Parakeet TDT-CTC 110M © NVIDIA, licensed under CC BY 4.0. Core ML conversions by FluidInference.")
                    Text("FluidAudio is licensed under Apache 2.0. Sparkle is licensed under MIT.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }

            Link("View source on GitHub", destination: URL(string: "https://github.com/mikwiseman/openramble")!)

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
