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
    @State private var pane: Pane

    init(state: AppState, pane: Pane = .general) {
        self.state = state
        _pane = State(initialValue: pane)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case general, setup, dictionary, about
        var id: Self { self }

        var title: String {
            switch self {
            case .general: return L10n.tr("General")
            case .setup: return L10n.tr("Setup")
            case .dictionary: return L10n.tr("Dictionary")
            case .about: return L10n.tr("About")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .setup: return "checklist"
            case .dictionary: return "character.book.closed"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        detail
            .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 640)
            // A page, not a panel: the same white as a document, so the few
            // things on it float.
            .background(Color(nsColor: .textBackgroundColor))
            .toolbar {
                // Where to go is the window's one control, so it floats: a
                // segmented control in the toolbar is Liquid Glass on macOS
                // 26, and the page scrolls beneath it.
                ToolbarItem(placement: .principal) {
                    Picker(L10n.tr("Settings"), selection: $pane) {
                        ForEach(Pane.allCases) { candidate in
                            Text(candidate.title).tag(candidate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel(L10n.tr("Settings"))
                }
            }
            .navigationTitle(L10n.tr("Settings"))
            .modifier(WithoutToolbarTitle())
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettings(state: state) { pane = .setup }
        case .setup: SetupSettings(state: state)
        case .dictionary: DictionarySettings(state: state)
        case .about:
            AboutView(
                updater: state.updater,
                revealSupportFolder: state.revealSupportFolder,
                detailedLogging: $state.detailedLogging,
            diagnostics: state.diagnostics
            )
        }
    }
}

// MARK: - General

/// What changes how dictation behaves. Everything done once to make it work
/// lives in Setup.
/// The few big decisions as blocks, everything else as rows.
///
/// A block's size comes from what it holds. The dictation key and the
/// microphone are the two things a person actually chooses here, so each gets
/// a block and its answer in large type. The rest are switches, and stay rows.
private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    let showSetup: () -> Void
    @State private var showClearConfirmation = false

    var body: some View {
        BlockPage {
            if let waiting = SetupBlock.reason(for: state) {
                SetupBlock(reason: waiting, action: showSetup)
            }

            HStack(alignment: .top, spacing: GlassTokens.Space.stack) {
                keyBlock
                microphoneBlock
            }
            .fixedSize(horizontal: false, vertical: true)

            BlockSection(
                L10n.tr("Shortcuts"),
                footer: L10n.tr("Paste last take puts your newest dictation into the app in front, and copies it while a password field or terminal protects typing. Record starts and stops a recording from any app.")
            ) {
                BlockRow(
                    title: L10n.tr("Paste last take"),
                    isChanged: state.lastTakeShortcut != SettingsDefaults.lastTakeShortcut,
                    revert: { state.lastTakeShortcut = SettingsDefaults.lastTakeShortcut }
                ) {
                    ShortcutRecorder(
                        shortcut: $state.lastTakeShortcut,
                        reserved: state.recordingShortcut.map { [$0: L10n.tr("Record")] } ?? [:]
                    )
                }
                .accessibilityHint(L10n.tr("Press this shortcut to paste the last take into the app in front"))
                BlockDivider()
                BlockRow(
                    title: L10n.tr("Record"),
                    isChanged: state.recordingShortcut != SettingsDefaults.recordingShortcut,
                    revert: { state.recordingShortcut = SettingsDefaults.recordingShortcut }
                ) {
                    ShortcutRecorder(
                        shortcut: $state.recordingShortcut,
                        reserved: state.lastTakeShortcut.map { [$0: L10n.tr("Paste last take")] } ?? [:]
                    )
                }
                .accessibilityHint(L10n.tr("Press this shortcut to start or stop a recording"))
            }

            BlockSection(L10n.tr("Dictation")) {
                toggleRow(
                    L10n.tr("Add a space after each dictation"),
                    hint: L10n.tr("For dictating in runs, so the next phrase does not arrive welded to the last word."),
                    isOn: $state.appendsTrailingSpace,
                    default: SettingsDefaults.appendsTrailingSpace
                )
                BlockDivider()
                toggleRow(
                    L10n.tr("Finish hands-free dictation on silence"),
                    hint: L10n.tr("Only in hands-free mode. While you hold the key, a pause is never treated as the end."),
                    isOn: $state.stopsOnSilence,
                    default: SettingsDefaults.stopsOnSilence
                )
                BlockDivider()
                toggleRow(
                    L10n.tr("Play a sound when something needs you"),
                    hint: L10n.tr("A quiet tone when the text didn't reach the field or nothing was recognized. A dictation that works stays silent."),
                    isOn: $state.soundsEnabled,
                    default: SettingsDefaults.soundsEnabled
                )
                BlockDivider()
                BlockRow(
                    title: L10n.tr("Dictation panel"),
                    isChanged: state.overlayPlacement != SettingsDefaults.overlayPlacement,
                    revert: { state.overlayPlacement = SettingsDefaults.overlayPlacement }
                ) {
                    Picker("", selection: $state.overlayPlacement) {
                        ForEach(DictationOverlayPlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(L10n.tr("Dictation panel"))
                    .accessibilityHint(L10n.tr("Places dictation feedback at the top or bottom of the active screen"))
                }
            }

            BlockSection(
                L10n.tr("History"),
                footer: L10n.tr("Your dictations live in the Library, next to your recordings. Starred ones stay past the limit.")
            ) {
                BlockRow(title: L10n.tr("History keeps")) {
                    Picker(L10n.tr("Keep"), selection: $state.historyLimit) {
                        ForEach([5, 10, 20, 50], id: \.self) { count in
                            Text(L10n.tr("Last %@", String(describing: count))).tag(count)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(L10n.tr("History keeps"))
                    .accessibilityHint(L10n.tr("How many dictations to keep, with their audio"))
                }
                BlockDivider()
                BlockRow(title: L10n.tr("Dictations and their audio")) {
                    HStack(spacing: 8) {
                        Button(L10n.tr("Show in Finder")) { state.revealHistoryAudio() }
                            .disabled(state.history.isEmpty)
                            .accessibilityHint(L10n.tr("Opens the folder holding the audio kept with these dictations"))
                        Button(L10n.tr("Delete All"), role: .destructive) { showClearConfirmation = true }
                            .disabled(state.history.isEmpty)
                    }
                }
            }
            .confirmationDialog(
                L10n.tr("Delete all dictation history?"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.tr("Delete All"), role: .destructive) { state.clearHistory() }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("The transcripts and their recordings are removed from this Mac."))
            }

            BlockSection("OpenRamble", footer: PrivacySentence.text) {
                BlockRow(title: L10n.tr("Interface language")) {
                    LanguagePicker().labelsHidden()
                }
                BlockDivider()
                BlockRow(
                    title: L10n.tr("Show OpenRamble in"),
                    isChanged: state.presence != SettingsDefaults.presence,
                    revert: { state.presence = SettingsDefaults.presence }
                ) {
                    Picker("", selection: $state.presence) {
                        ForEach(AppPresence.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(L10n.tr("Show OpenRamble in"))
                    .accessibilityHint(L10n.tr("There is no option to hide it entirely — an app you cannot see is one you cannot open again."))
                }
                BlockDivider()
                toggleRow(
                    L10n.tr("Launch at login"),
                    hint: L10n.tr("Starts OpenRamble automatically when you log in"),
                    isOn: $state.launchAtLogin,
                    default: SettingsDefaults.launchAtLogin
                )
            }
        }
    }

    // MARK: The two blocks

    private var isKeyHeld: Bool {
        (state.dictationState == .preparing || state.dictationState == .listening)
            && !state.isHandsFreeActive
    }

    /// The key, as an object: the one thing on this page a hand knows.
    private var keyBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BlockLabel(L10n.tr("Dictation key"))
                Spacer()
                RevertToDefault(
                    isChanged: state.hotkey != SettingsDefaults.hotkey,
                    revert: { state.hotkey = SettingsDefaults.hotkey }
                )
            }
            Spacer(minLength: 20)
            // The cap goes down when the real key does: hold it here and the
            // setting answers the hand.
            DictationKeyMenu(hotkey: $state.hotkey, isPressed: isKeyHeld)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 20)
            if let warning = state.hotkeyWarning {
                attention(warning)
                    .accessibilityLabel(L10n.tr("Key warning. %@", String(describing: warning)))
            } else {
                Text(L10n.tr("Hold to talk. Double-press for hands-free."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .topLeading)
        .contentBlock()
    }

    /// The microphone, by the name of the one a take would use right now.
    private var microphoneBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BlockLabel(L10n.tr("Microphone"))
                Spacer()
                RevertToDefault(
                    isChanged: state.inputDeviceUID != nil,
                    revert: { state.inputDeviceUID = nil }
                )
            }
            Spacer(minLength: 20)
            Menu {
                Picker(L10n.tr("Microphone"), selection: $state.inputDeviceUID) {
                    Text(L10n.tr("System default")).tag(String?.none)
                    ForEach(state.availableInputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(microphoneName)
                        .font(.system(size: 24, weight: .regular))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(L10n.tr("Microphone"))
            .accessibilityValue(microphoneName)
            .accessibilityHint(L10n.tr("Which input to record through. The system default follows whatever your Mac is using."))
            Spacer(minLength: 20)
            if let notice = state.inputDeviceNotice {
                attention(notice)
            } else {
                Text(state.inputDeviceUID == nil ? L10n.tr("Follows your Mac.") : L10n.tr("Always this one, while it is connected."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .topLeading)
        .contentBlock()
    }

    /// The microphone a take would use right now, by name.
    private var microphoneName: String {
        AudioInputDevices.recordingName(of: state.preferredInputDeviceID)
            ?? L10n.tr("System default")
    }

    // MARK: Pieces

    private func attention(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StateGlyphView(glyph: .attention, size: 12)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func toggleRow(
        _ title: String,
        hint: String,
        isOn: Binding<Bool>,
        default defaultValue: Bool
    ) -> some View {
        BlockRow(
            title: title,
            isChanged: isOn.wrappedValue != defaultValue,
            revert: { isOn.wrappedValue = defaultValue }
        ) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityHint(hint)
        }
    }
}

/// The window's name stays for the Window menu and for VoiceOver; in the
/// toolbar the switcher says where you are, and a title beside it only
/// repeats the window.
struct WithoutToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// The privacy promise, in one sentence that names its two exceptions.
enum PrivacySentence {
    static var text: String {
        L10n.tr("Speech is recognized on this Mac. OpenRamble goes online only to download the speech model and to check for updates.")
    }
}

/// A block that appears only while setup is unfinished, and says the one
/// thing that is missing. A complete setup costs zero pixels.
struct SetupBlock: View {
    let reason: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                BlockLabel(L10n.tr("Almost ready"))
                Text(reason)
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(L10n.tr("Set up"), action: action)
                .buttonStyle(InkButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentBlock(.attention)
        .accessibilityElement(children: .contain)
    }

    /// What is missing, in the order a person has to fix it, or `nil` when
    /// nothing waits on them.
    @MainActor
    static func reason(for state: AppState) -> String? {
        reason(
            microphoneGranted: state.microphoneGranted,
            accessibilityGranted: state.accessibilityGranted,
            modelState: state.modelState
        )
    }

    static func reason(
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        modelState: ModelState
    ) -> String? {
        if !microphoneGranted {
            return L10n.tr("Allow the microphone so OpenRamble can hear you.")
        }
        if !accessibilityGranted {
            return L10n.tr("Allow Accessibility so your words can land.")
        }
        switch modelState {
        case .notInstalled:
            return L10n.tr("Download the speech model to start dictating.")
        case .repairRequired, .failed:
            return L10n.tr("The speech model needs a repair.")
        case .downloading, .verifying, .deleting, .ready:
            // Work in progress is the app's job, not the person's.
            return nil
        }
    }
}

private struct SetupSettings: View {
    @ObservedObject var state: AppState
    @State private var showDeleteConfirmation = false
    @State private var showAccessibilityRepairConfirmation = false

    var body: some View {
        BlockPage {
            BlockSection(
                L10n.tr("Speech model"),
                footer: L10n.tr("The speech model runs entirely on this Mac. Once downloaded and verified, recognition works offline — audio is never uploaded. History keeps your recent dictations with their audio, as many as you choose to keep. Other dictation audio is retained only after a disclosed technical failure or interrupted process, then pruned within seven days. Interrupted dictations appear in History, with the rest of your recordings.")
            ) {
                BlockCell {
                    ModelStatusView(
                        status: ModelStatus.make(
                            state: state.modelState,
                            preparation: state.enginePreparation,
                            place: .settings,
                            downloadMegabytes: state.remainingDownloadMegabytes,
                            isEngineReady: state.isEngineReady,
                            isPreparingEngine: state.isPreparingEngine,
                            hasMirror: state.modelHasMirror
                        ),
                        install: state.installModel,
                        cancel: state.cancelModelInstall,
                        // Delete sits beside ordinary buttons and used to act
                        // on the first click: a miss cost half a gigabyte and
                        // a new download. Nothing undoes it, so it asks.
                        delete: { showDeleteConfirmation = true }
                    )
                }
                if let upgrade = state.upgradeState {
                    BlockDivider()
                    BlockCell {
                        ModelStatusView(
                            status: ModelStatus.upgrade(state: upgrade, downloadMegabytes: state.remainingDownloadMegabytes),
                            install: state.installModel,
                            cancel: state.cancelModelInstall,
                            delete: {}
                        )
                    }
                }
            }
            .confirmationDialog(
                L10n.tr("Delete the recognition model?"),
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.tr("Delete Model"), role: .destructive) { state.deleteModel() }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("Dictation stops working until you download the model again — that's another %@ MB over the network.", String(describing: state.fullModelDownloadMegabytes)))
            }

            BlockSection(
                L10n.tr("Permissions"),
                footer: L10n.tr("Finished text is pasted through the clipboard; its previous contents are restored shortly afterward.")
            ) {
                BlockCell {
                    PermissionRow(
                        status: PermissionStatus.accessibility(
                            state: state.accessibilityState,
                            detail: L10n.tr("Notices your dictation key and types the finished text at your cursor."),
                        ),
                        action: performAccessibilityAction
                    )
                    if needsAccessibilityRepair {
                        HStack {
                            Button(L10n.tr("Show in Finder")) {
                                state.revealApplicationForAccessibility()
                            }
                            Button(L10n.tr("Open System Settings")) {
                                state.openAccessibilitySettings()
                            }
                        }
                    }
                    if AccessibilityRepairLink.isShown(
                        state: state.accessibilityState,
                        returnedWithoutGrant: state.accessibilityReturnedWithoutGrant
                    ) {
                        AccessibilityRepairLinkButton(modelState: state.modelState) {
                            showAccessibilityRepairConfirmation = true
                        }
                    }
                }
                BlockDivider()
                BlockCell {
                    PermissionRow(
                        status: PermissionStatus(
                            title: L10n.tr("Microphone"),
                            detail: L10n.tr("Hears your voice during dictation and recordings you start."),
                            granted: state.microphoneGranted
                        ),
                        action: state.requestMicrophone
                    )
                }
                BlockDivider()
                BlockCell {
                    PermissionRow(
                        status: PermissionStatus.systemAudio(mode: state.systemAudioPermission),
                        action: state.performSystemAudioAction
                    )
                }
            }

            CommandLineToolSettings()
        }
        .task { await state.refreshModelState() }
        // Permissions are granted in System Settings, and a person coming
        // back here should see the fresh state, not the one they left.
        .task { state.refreshPermissions() }
        .confirmationDialog(
            L10n.tr("Repair Accessibility access?"),
            isPresented: $showAccessibilityRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Reset OpenRamble's access and relaunch"), role: .destructive) {
                state.repairAccessibility()
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("macOS will remove only OpenRamble's Accessibility entries. After the relaunch you will need to grant access again."))
        }
    }

    private var needsAccessibilityRepair: Bool {
        if case .failed = state.accessibilityState { return true }
        return false
    }

    private func performAccessibilityAction() {
        switch state.accessibilityState {
        case .denied:
            state.requestAccessibility()
        case .waitingForSettings:
            state.openAccessibilitySettings()
        case .failed:
            showAccessibilityRepairConfirmation = true
        case .repairing, .granted:
            break
        }
    }
}

/// The secondary way out beside the Accessibility row; see
/// `AccessibilityRepairLink`. A link, not a button: the primary action is
/// still to turn the switch on in System Settings.
struct AccessibilityRepairLinkButton: View {
    let modelState: ModelState
    let action: () -> Void

    var body: some View {
        let enabled = AccessibilityRepairLink.isEnabled(modelState: modelState)
        Button(L10n.tr("Already on? Repair"), action: action)
            .buttonStyle(.link)
            .font(.caption)
            .disabled(!enabled)
            .help(enabled ? "" : L10n.tr("Available once the model has downloaded."))
            .accessibilityHint(
                enabled
                    ? L10n.tr("Removes OpenRamble's old Accessibility entry and relaunches the app.")
                    : L10n.tr("Available once the model has downloaded.")
            )
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
            } else if status.granted {
                Label(L10n.tr("Granted"), systemImage: "checkmark.circle.fill")
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

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject var state: AppState
    @State private var spoken = ""
    @State private var written = ""
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: DictionaryTransferFile?

    var body: some View {
        BlockPage {
            if let problem = state.dictionaryProblem {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.tr("Dictionary can't be edited"), systemImage: "lock.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text(problem.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentBlock(.attention)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.tr("Dictionary can't be edited. %@", String(describing: problem.message)))
            }

            BlockSection(
                L10n.tr("Replacements"),
                footer: L10n.tr("Common technical terms are handled automatically. Add personal names or phrases the model hears differently.")
            ) {
                if state.replacements.isEmpty {
                    VStack(spacing: 4) {
                        Text(L10n.tr("No personal replacements yet"))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("Add a pair below: what the model hears on the left, what should be written on the right."))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .padding(.horizontal, GlassTokens.Space.stack)
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(Array(state.replacements.enumerated()), id: \.element.id) { index, replacement in
                        if index > 0 { BlockDivider() }
                        HStack {
                            Text(replacement.spoken)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(replacement.written)
                            if replacement.noAcousticBoost {
                                Spacer(minLength: 8)
                                Text(L10n.tr("text only"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Spacer(minLength: 8)
                            }
                            Button {
                                removeReplacement(replacement)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!state.isDictionaryEditable)
                            .accessibilityLabel(
                                L10n.tr("Delete replacement “%@” to “%@”", String(describing: replacement.spoken), String(describing: replacement.written))
                            )
                        }
                        .padding(.horizontal, GlassTokens.Space.stack)
                        .frame(minHeight: GlassTokens.Block.unit - 8)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(
                            replacement.noAcousticBoost
                                ? L10n.tr("Heard as “%@”, written as “%@”, text only — not used to help recognition", String(describing: replacement.spoken), String(describing: replacement.written))
                                : L10n.tr("Heard as “%@”, written as “%@”", String(describing: replacement.spoken), String(describing: replacement.written))
                        )
                    }
                }
                BlockDivider()
                // Adding a pair lives in the same block as the pairs: the
                // list ends where the next one starts.
                HStack(spacing: 8) {
                    TextField(L10n.tr("Heard as"), text: $spoken, prompt: Text(L10n.tr("Spoken phrase")))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(L10n.tr("Heard as"))
                        .onSubmit(addReplacement)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    TextField(L10n.tr("Write as"), text: $written, prompt: Text(L10n.tr("Final spelling")))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(L10n.tr("Write as"))
                        .onSubmit(addReplacement)
                    Button(L10n.tr("Add"), action: addReplacement)
                        .disabled(!canAddReplacement)
                        .accessibilityLabel(L10n.tr("Add replacement"))
                        .accessibilityHint(addReplacementHint)
                }
                .padding(.horizontal, GlassTokens.Space.stack)
                .frame(minHeight: GlassTokens.Block.unit)
            } accessory: {
                HStack(spacing: 12) {
                    Button(L10n.tr("Import…")) { showImporter = true }
                        .disabled(!state.isDictionaryEditable)
                        .accessibilityHint(L10n.tr("Adds phrases from an OpenRamble dictionary file"))
                    Button(L10n.tr("Export…")) {
                        guard let data = try? state.exportedDictionary() else { return }
                        exportDocument = DictionaryTransferFile(data: data)
                        showExporter = true
                    }
                    .disabled(state.replacements.isEmpty)
                    .accessibilityHint(L10n.tr("Saves all phrases to a file"))
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }

            BlockSection(
                L10n.tr("Personalization"),
                footer: L10n.tr("Off by default. After a paste, OpenRamble can re-read only that field at 8 and 25 seconds to learn a correction. The content stays on this Mac.")
            ) {
                BlockRow(title: L10n.tr("Learn from your edits")) {
                    Toggle("", isOn: $state.learnFromEdits)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(L10n.tr("Learn from your edits"))
                        .accessibilityHint(L10n.tr("Reads back the field it pasted into, to learn words you fix by hand"))
                }
            }
        }
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
                    state.reportDictionaryFileProblem(L10n.tr("The file couldn't be opened."))
                }
            case let .failure(error):
                state.reportDictionaryFileProblem(
                    L10n.tr("The file couldn't be opened: %@", String(describing: error.localizedDescription))
                )
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: L10n.tr("OpenRamble Dictionary")
        ) { result in
            // The file appearing where the person chose is the success signal;
            // only a failure needs words.
            if case let .failure(error) = result {
                state.reportDictionaryFileProblem(
                    L10n.tr("The dictionary couldn't be exported: %@", String(describing: error.localizedDescription))
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
            return L10n.tr("The dictionary can't be edited until the previous data has been read")
        }
        return canAddReplacement
            ? L10n.tr("Adds this replacement to future dictations")
            : L10n.tr("Fill in both fields")
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
    @Binding var detailedLogging: Bool
    let diagnostics: DictationLogFile
    @State private var isSavingReport = false
    @State private var reportSaveFailed = false

    /// The one link in this window. An app whose whole claim is that speech
    /// never leaves the machine should be readable by anyone who doubts it.
    static let sourceURL = URL(string: "https://github.com/mikwiseman/openramble")!

    private func saveErrorReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "OpenRamble-Error-Report.zip"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isSavingReport = true
            Task { @MainActor in
                defer { isSavingReport = false }
                do {
                    let journal = diagnostics
                    try await Task.detached(priority: .utility) {
                        try ErrorReport.save(to: url, journal: journal)
                    }.value
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch { reportSaveFailed = true }
            }
        }
    }

    /// Version and build number. The first thing asked in any bug report is
    /// and the only place where this could be read is not in the application
    /// it was completely: there is no icon in the Dock, “About” from the main menu is unreachable.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return L10n.tr("Version %@ (%@)", String(describing: marketing), String(describing: build))
    }

    @State private var showsCredits = false

    var body: some View {
        BlockPage {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenRamble")
                        .font(.system(size: 22, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.tr("Private dictation and recording for your Mac"))
                        .foregroundStyle(.secondary)
                    Text(version)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentBlock()

            BlockSection(
                L10n.tr("Updates"),
                footer: L10n.tr("On by default so security fixes can reach you. Once a day, the app reads a small version list. The request contains the app version and your IP address, but no device profile or dictated content. Turn this off to stop scheduled network access.")
            ) {
                BlockRow(title: L10n.tr("Check for updates automatically")) {
                    // Disabled together with the updater: a switch that
                    // promises daily checks beside "updates are not working"
                    // would be a quiet lie.
                    Toggle("", isOn: $updater.automaticChecksEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(L10n.tr("Check for updates automatically"))
                        .accessibilityHint(L10n.tr("The only switch that changes the app's network behavior"))
                        .disabled(updater.startupFailure != nil)
                }
                BlockDivider()
                BlockCell {
                    Button(L10n.tr("Check Now"), action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                    if let failure = updater.startupFailure {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(L10n.tr("Updates are not working"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(StatusColorRole.attention.color)
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(L10n.tr("Updates are not working. %@", String(describing: failure)))
                    }
                }
            }

            BlockSection(
                L10n.tr("Privacy"),
                footer: L10n.tr("No account, analytics, or cloud transcription. Reports contain technical events and available crash details, never your speech. Nothing is sent automatically. Network access is limited to model downloads and update checks. Models and any recordings kept after a failure live in the support folder.")
            ) {
                BlockCell {
                    Text(PrivacySentence.text)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                BlockDivider()
                BlockRow(
                    title: L10n.tr("Keep local diagnostics"),
                    isChanged: detailedLogging != SettingsDefaults.detailedLogging,
                    revert: { detailedLogging = SettingsDefaults.detailedLogging }
                ) {
                    Toggle("", isOn: $detailedLogging)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(L10n.tr("Keep local diagnostics"))
                        .accessibilityHint(
                            L10n.tr("Keeps technical events for up to 7 days, limited to 5 MB. No speech or personal content. Turning this off clears the journal.")
                        )
                }
                BlockDivider()
                BlockCell {
                    HStack(spacing: 12) {
                        Button(isSavingReport ? L10n.tr("Saving Report…") : L10n.tr("Save Error Report…"), action: saveErrorReport)
                            .disabled(isSavingReport)
                            .accessibilityHint(L10n.tr("Saves a ZIP with local technical events and available crash reports. Nothing is sent automatically."))
                        Button(L10n.tr("Reveal Support Folder"), action: revealSupportFolder)
                            .accessibilityLabel(L10n.tr("Reveal Support Folder"))
                            .accessibilityHint(L10n.tr("Opens the folder with downloaded models and any recordings kept after a failure"))
                    }
                }
            }

            BlockSection(L10n.tr("Credits")) {
                BlockCell {
                    DisclosureGroup(L10n.tr("Model and library credits"), isExpanded: $showsCredits) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.tr("Speech recognition runs on transcribe.cpp by CJ Pais and the Handy team, licensed under MIT. Sparkle is licensed under MIT."))
                            Text(L10n.tr("Parakeet Ultra © Moondream and Parakeet TDT 0.6B v3 © NVIDIA, licensed under CC BY 4.0. GGUF conversions by handy-computer."))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    }
                    Link(L10n.tr("View source on GitHub"), destination: URL(string: "https://github.com/mikwiseman/openramble")!)
                }
            }
        }
        .alert(L10n.tr("Couldn’t save the report"), isPresented: $reportSaveFailed) {
            Button(L10n.tr("OK"), role: .cancel) {}
        } message: {
            Text(L10n.tr("Try another location with available disk space."))
        }
    }
}
