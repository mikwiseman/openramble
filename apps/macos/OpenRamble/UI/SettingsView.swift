import AppKit
import DictationCore
import LocalASR
import SwiftUI
import UniformTypeIdentifiers

/// Five panes behind a sidebar.
///
/// A sidebar rather than a tab strip, because on macOS a sidebar is genuinely
/// translucent: the system gives `NavigationSplitView` real vibrancy that
/// samples the desktop behind the window. No bridge, no override, nothing to
/// fight — which is exactly why the tab strip could not be made to do it. Its
/// chrome keeps an opaque background whatever is placed behind it, and the
/// attempt left a hard band across the top of the window.
///
/// So the glass here is the system's own, on the surface the system already
/// treats as floating chrome, and the detail pane stays content.
struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var pane: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general, recognition, history, dictionary, about
        var id: Self { self }

        var title: String {
            switch self {
            case .general: return "General"
            case .recognition: return "Recognition"
            case .history: return "History"
            case .dictionary: return "Dictionary"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .recognition: return "waveform"
            case .history: return "clock.arrow.circlepath"
            case .dictionary: return "character.book.closed"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { candidate in
                Label(candidate.title, systemImage: candidate.symbol)
                    .tag(candidate)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 178, max: 200)
            // The sidebar's own translucency, which is the whole point of
            // using one here.
            .scrollContentBackground(.hidden)
            // Sidebar content scrolls under the title bar, which is ordinary
            // on macOS — but only when the title bar has a material to hide it
            // behind. This window's was transparent, so a scrolled list showed
            // through raw and collided with the traffic lights: the
            // "Dictionary" row rendered straight underneath them.
            .toolbarBackground(.visible, for: .windowToolbar)
            // Five fixed panes always fit, so there is nothing to scroll — and
            // a list that cannot scroll cannot slide its rows up under the
            // traffic lights, which is what kept happening. Giving the title
            // bar a material was not enough on its own: the rows still moved,
            // they were merely harder to see doing it.
            .scrollDisabled(true)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, idealWidth: 720, minHeight: 540, idealHeight: 540)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettings(state: state)
        case .recognition: RecognitionSettings(state: state)
        case .history: HistoryView(state: state)
        case .dictionary: DictionarySettings(state: state)
        case .about:
            AboutView(
                updater: state.updater,
                revealSupportFolder: state.revealSupportFolder,
                appearance: $state.appearance,
                detailedLogging: $state.detailedLogging
            )
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @State private var showAccessibilityRepairConfirmation = false

    var body: some View {
        Form {
            Section {
                SettingRow(
                    title: "Dictation key",
                    isChanged: state.hotkey != SettingsDefaults.hotkey,
                    revert: { state.hotkey = SettingsDefaults.hotkey }
                ) {
                    Picker("", selection: $state.hotkey) {
                        ForEach(DictationHotkey.allCases, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Dictation key")
                    .accessibilityHint("The key you hold down while dictating")
                }

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
                            .foregroundStyle(StatusColorRole.attention.color)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Key warning. \(warning)")
                }
                SettingRow(
                    title: "Copy last dictation",
                    isChanged: state.copyShortcut != SettingsDefaults.copyShortcut,
                    revert: { state.copyShortcut = SettingsDefaults.copyShortcut }
                ) {
                    ShortcutRecorder(shortcut: $state.copyShortcut)
                }
                .accessibilityHint("Press this shortcut to put the last dictation back on the clipboard")
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Hold to talk, or double-press for hands-free dictation. Press once more to finish.")
            }

            Section("Behavior") {
                // Autorun was written and worked, but it was impossible to enable it
                // nowhere: hotkey utility, not survived
                // reboot, indistinguishable from a broken one - the key is just
                // is silent, and there is no one to explain it to.
                SettingRow(
                    title: "Launch at login",
                    isChanged: state.launchAtLogin != SettingsDefaults.launchAtLogin,
                    revert: { state.launchAtLogin = SettingsDefaults.launchAtLogin }
                ) {
                    Toggle("", isOn: $state.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Launch at login")
                        .accessibilityHint("Starts OpenRamble automatically when you log in")
                }
                SettingRow(
                    title: "Also copy dictations to the clipboard",
                    isChanged: state.copiesToClipboard != SettingsDefaults.copiesToClipboard,
                    revert: { state.copiesToClipboard = SettingsDefaults.copiesToClipboard }
                ) {
                    Toggle("", isOn: $state.copiesToClipboard)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Also copy dictations to the clipboard")
                        .accessibilityHint(
                            "Leaves each finished dictation on the clipboard of this Mac. Off by default — the clipboard is shared with everything else running here."
                        )
                }
                SettingRow(
                    title: "Add a space after each dictation",
                    isChanged: state.appendsTrailingSpace != SettingsDefaults.appendsTrailingSpace,
                    revert: { state.appendsTrailingSpace = SettingsDefaults.appendsTrailingSpace }
                ) {
                    Toggle("", isOn: $state.appendsTrailingSpace)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Add a space after each dictation")
                        .accessibilityHint(
                            "For dictating in runs, so the next phrase does not arrive welded to the last word."
                        )
                }
                SettingRow(
                    title: "Play a sound when something needs you",
                    isChanged: state.soundsEnabled != SettingsDefaults.soundsEnabled,
                    revert: { state.soundsEnabled = SettingsDefaults.soundsEnabled }
                ) {
                    Toggle("", isOn: $state.soundsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Play a sound when something needs you")
                        .accessibilityHint(
                            "A quiet tone when the text didn't reach the field or nothing was recognized. A dictation that works stays silent."
                        )
                }
                SettingRow(
                    title: "Microphone",
                    isChanged: state.inputDeviceUID != nil,
                    revert: { state.inputDeviceUID = nil }
                ) {
                    Picker("", selection: $state.inputDeviceUID) {
                        Text("System default").tag(String?.none)
                        ForEach(state.availableInputDevices) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Microphone")
                    .accessibilityHint("Which input to record through. The system default follows whatever your Mac is using.")
                }
                if let notice = state.inputDeviceNotice {
                    // Said out loud rather than swapped silently: someone who
                    // chose a headset and quietly got the laptop lid would
                    // only find out from the transcript.
                    Label {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(StatusColorRole.attention.color)
                    }
                    .accessibilityElement(children: .combine)
                }
                SettingRow(
                    title: "Finish hands-free dictation on silence",
                    isChanged: state.stopsOnSilence != SettingsDefaults.stopsOnSilence,
                    revert: { state.stopsOnSilence = SettingsDefaults.stopsOnSilence }
                ) {
                    Toggle("", isOn: $state.stopsOnSilence)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Finish hands-free dictation on silence")
                        .accessibilityHint(
                            "Only in hands-free mode. While you hold the key, a pause is never treated as the end."
                        )
                }
                SettingRow(
                    title: "Show OpenRamble in",
                    isChanged: state.presence != SettingsDefaults.presence,
                    revert: { state.presence = SettingsDefaults.presence }
                ) {
                    Picker("", selection: $state.presence) {
                        ForEach(AppPresence.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Show OpenRamble in")
                    .accessibilityHint("There is no option to hide it entirely — an app you cannot see is one you cannot open again.")
                }
                SettingRow(
                    title: "Dictation panel",
                    isChanged: state.overlayPlacement != SettingsDefaults.overlayPlacement,
                    revert: { state.overlayPlacement = SettingsDefaults.overlayPlacement }
                ) {
                    Picker("", selection: $state.overlayPlacement) {
                        ForEach(DictationOverlayPlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Dictation panel")
                    .accessibilityHint("Places dictation feedback at the top or bottom of the active screen")
                }
                Picker("Unload model", selection: $state.modelUnloadTimeout) {
                    ForEach(IdleUnloadPolicy.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .accessibilityHint(
                    "Frees the speech model's memory after this much idle time. It reloads under your voice at the next dictation."
                )
            }

            Section {
                PermissionRow(
                    status: PermissionStatus.accessibility(
                        state: state.accessibilityState,
                        detail: "Notices your dictation key and types the finished text at your cursor.",
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
                        detail: "Hears you only while you hold the dictation key.",
                        granted: state.microphoneGranted
                    ),
                    action: state.requestMicrophone
                )
            } header: {
                Text("Permissions")
            } footer: {
                Text("Finished text is pasted through the clipboard; its previous contents are restored shortly afterward.")
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
                    .foregroundStyle(StatusColorRole.success.color)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    // The checkmark has already been read as a string value: second time
                    // “issued” without an owner only gets in the way.
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Recognition

private struct RecognitionSettings: View {
    @ObservedObject var state: AppState
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            Section {
                ModelStatusView(
                    status: ModelStatus.make(
                        state: state.modelState,
                        preparation: state.enginePreparation,
                        place: .settings,
                        downloadMegabytes: state.remainingDownloadMegabytes,
                        isEngineReady: state.isEngineReady,
                        isPreparingEngine: state.isPreparingEngine
                    ),
                    install: state.installModel,
                    cancel: state.cancelModelInstall,
                    // Delete is next to regular buttons and earlier
                    // worked on the first click: a miss cost half
                    // gigabyte and new download. There is nothing to cancel this, it means
                    // ask.
                    delete: { showDeleteConfirmation = true }
                )
                // Retained audio moved out of the daily menu: it is announced
                // by the failure notice when it happens, and findable here for
                // as long as it exists.
            } header: {
                Text("Speech model")
            } footer: {
                Text("Parakeet TDT 0.6B v3 runs entirely on this Mac. Once downloaded and verified, recognition works offline — audio is never uploaded. Audio is retained only after a disclosed technical failure or interrupted process, then pruned within seven days. Interrupted dictations appear in History, with the rest of your recordings.")
            }

        }
        .formStyle(.grouped)
        .task { await state.refreshModelState() }
        .confirmationDialog(
            "Delete the recognition model?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) { state.deleteModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dictation stops working until you download the model again — that's another \(state.fullModelDownloadMegabytes) MB over the network.")
        }
    }
}

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject var state: AppState
    @State private var spoken = ""
    @State private var written = ""
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: DictionaryTransferFile?

    var body: some View {
        Form {
            if let problem = state.dictionaryProblem {
                Section {
                    // The dictionary is write-locked. You have to say this
                    // here: the person stands exactly on the page where he is going
                    // edit it, and must find out before you start.
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Dictionary can't be edited", systemImage: "lock.fill")
                            .foregroundStyle(StatusColorRole.attention.color)
                        Text(problem.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Dictionary can't be edited. \(problem.message)")
                }
            }

            Section {
                // An empty dictionary is common for a new person, and it used
                // to be just a half-window gap without a single word.
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                } else {
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
                            } else {
                                Spacer(minLength: 8)
                            }
                            // A visible way out for every row: the delete key
                            // works too, but nobody can discover that.
                            Button {
                                removeReplacement(replacement)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!state.isDictionaryEditable)
                            .accessibilityLabel(
                                "Delete replacement “\(replacement.spoken)” to “\(replacement.written)”"
                            )
                        }
                        // The row is read whole: "sentry", arrow and "Sentry"
                        // separately do not mean anything. The delete button
                        // stays its own element.
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(
                            replacement.noAcousticBoost
                                ? "Heard as “\(replacement.spoken)”, written as “\(replacement.written)”, text only — not used to help recognition"
                                : "Heard as “\(replacement.spoken)”, written as “\(replacement.written)”"
                        )
                    }
                    .onDelete(perform: state.removeReplacements)
                }
            } header: {
                HStack {
                    Text("Replacements")
                    Spacer()
                    // The dictionary is the one piece of dictation state worth
                    // carrying to another Mac — quiet header actions, like
                    // System Settings' own list tools.
                    Button("Import…") { showImporter = true }
                        .disabled(!state.isDictionaryEditable)
                        .accessibilityHint("Adds phrases from an OpenRamble dictionary file")
                    Button("Export…") {
                        guard let data = try? state.exportedDictionary() else { return }
                        exportDocument = DictionaryTransferFile(data: data)
                        showExporter = true
                    }
                    .disabled(state.replacements.isEmpty)
                    .accessibilityHint("Saves all phrases to a file")
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("Common technical terms are handled automatically. Add personal names or phrases the model hears differently.")
            }

            Section {
                // The only place where the application reads the content of someone else's
                // windows. Off by default, and the footer says exactly what is
                // read - otherwise the choice is not conscious.
                Toggle("Learn from your edits", isOn: $state.learnFromEdits)
                    .accessibilityHint("Reads back the field it pasted into, to learn words you fix by hand")
            } header: {
                Text("Personalization")
            } footer: {
                Text("Off by default. After a paste, OpenRamble can re-read only that field at 8 and 25 seconds to learn a correction. The content stays on this Mac.")
            }

            Section("Add replacement") {
                // A composer, not a settings value: the grouped form's default
                // trailing-aligned fields are for tweaking short values, and
                // typing a new phrase against the right edge reads backwards.
                // Two bordered leading fields mirror the rows above — what is
                // heard flows into what gets written.
                HStack(spacing: 8) {
                    TextField("Heard as", text: $spoken, prompt: Text("Spoken phrase"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel("Heard as")
                        .onSubmit(addReplacement)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    TextField("Write as", text: $written, prompt: Text("Final spelling"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel("Write as")
                        .onSubmit(addReplacement)
                    Button("Add", action: addReplacement)
                        .disabled(!canAddReplacement)
                        .accessibilityLabel("Add replacement")
                        .accessibilityHint(addReplacementHint)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case let .success(url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Path-based read on purpose: URL-loading APIs can reach the
                // network, and the shipping network surface must stay exactly
                // two places. The picker only ever hands over local files.
                if url.isFileURL, let data = FileManager.default.contents(atPath: url.path) {
                    state.importDictionary(from: data)
                } else {
                    state.reportDictionaryFileProblem("The file couldn't be opened.")
                }
            case let .failure(error):
                state.reportDictionaryFileProblem(
                    "The file couldn't be opened: \(error.localizedDescription)"
                )
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "OpenRamble Dictionary"
        ) { result in
            // The file appearing where the person chose is the success signal;
            // only a failure needs words.
            if case let .failure(error) = result {
                state.reportDictionaryFileProblem(
                    "The dictionary couldn't be exported: \(error.localizedDescription)"
                )
            }
        }
    }

    private func removeReplacement(_ replacement: DictionaryReplacement) {
        guard let index = state.replacements.firstIndex(of: replacement) else { return }
        state.removeReplacements(at: IndexSet(integer: index))
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

/// The dictionary file as the save panel sees it.
private struct DictionaryTransferFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - About the program

private struct AboutView: View {
    // Sparkle reports its changes itself; they would not have reached through AppState.
    @ObservedObject var updater: SparkleUpdater
    let revealSupportFolder: () -> Void
    @Binding var appearance: AppAppearance
    @Binding var detailedLogging: Bool

    /// The one link in this window. An app whose whole claim is that speech
    /// never leaves the machine should be readable by anyone who doubts it.
    static let sourceURL = URL(string: "https://github.com/mikwiseman/openramble")!

    /// Where the system writes this app's logs.
    private func revealLogFolder() {
        let logs = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Logs", directoryHint: .isDirectory)
        NSWorkspace.shared.activateFileViewerSelecting([logs])
    }

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
        Form {
            Section {
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
                .padding(.vertical, 4)
            }

            Section("Appearance") {
                SettingRow(
                    title: "Theme",
                    isChanged: appearance != SettingsDefaults.appearance,
                    revert: { appearance = SettingsDefaults.appearance }
                ) {
                    Picker("", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Theme")
                    .accessibilityHint("Follow the system, or keep this app light or dark on its own")
                }
            }

            Section {
                // The switch goes out along with the update mechanism. Otherwise
                // it turned out to be a silent lie: next to it it says “no updates
                // work”, the person clicks the switch, the text below it
                // promises daily checks - and the setup goes into
                // the mechanism is not running and does nothing.
                Toggle("Check for updates automatically", isOn: $updater.automaticChecksEnabled)
                    .accessibilityHint("The only switch that changes the app's network behavior")
                    .disabled(updater.startupFailure != nil)
                Button("Check Now", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                if let failure = updater.startupFailure {
                    // You can’t be silent: otherwise a person will think that
                    // updates come, but they don't arrive.
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Updates are not working", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(StatusColorRole.attention.color)
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Updates are not working. \(failure)")
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("On by default so security fixes can reach you. Once a day, the app reads a small version list. The request contains the app version and your IP address, but no device profile or dictated content. Turn this off to stop scheduled network access.")
            }

            Section {
                Label {
                    Text("Speech stays on this Mac")
                        .font(.headline)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(StatusColorRole.success.color)
                        .font(.title3)
                }
                .accessibilityElement(children: .combine)
                SettingRow(
                    title: "Keep detailed logs",
                    isChanged: detailedLogging != SettingsDefaults.detailedLogging,
                    revert: { detailedLogging = SettingsDefaults.detailedLogging }
                ) {
                    Toggle("", isOn: $detailedLogging)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Keep detailed logs")
                        .accessibilityHint(
                            "Keeps the engine's notes about loading and warming, which macOS otherwise discards. Timing is always recorded either way, and nothing you say is ever written."
                        )
                }
                Button("Open Log Folder", action: revealLogFolder)
                    // Logs are what a person can attach to a bug report. They
                    // hold no dictated text — the privacy rules forbid it — so
                    // there is nothing here to warn about before opening.
                    .accessibilityLabel("Open log folder")
                Button("Reveal Support Folder", action: revealSupportFolder)
                    // The title alone does not survive into the accessibility
                    // tree on this Form layout — VoiceOver would announce an
                    // unnamed button.
                    .accessibilityLabel("Reveal Support Folder")
                    .accessibilityHint("Opens the folder with downloaded models and any recordings kept after a failure")
            } header: {
                Text("Privacy")
            } footer: {
                Text("No account, analytics, or cloud transcription. Network access is limited to model downloads and update checks. Models and any recordings kept after a failure live in the support folder.")
            }

            Section("Credits") {
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
            }
        }
        .formStyle(.grouped)
    }
}
