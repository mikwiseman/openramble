import DictationCore
import LocalASR
import SwiftUI

/// First launch: from installation to the first dictated phrase.
///
/// Three focused steps take a person from installation to a verified first
/// dictation. The window is one calm surface: system typography, content on
/// quiet material cards, and exactly one Liquid Glass element — the primary
/// button in the footer.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// “Reduce Motion” in universal access. Transition between steps -
    /// decoration, and the person who disabled it should not get it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: OnboardingStep = .welcome
    /// Direction of the last navigation: forward slides left, back slides
    /// right. Symmetric paths make the wizard predictable — a step returns
    /// the same way it left.
    @State private var movingForward = true
    /// What the person dictated for the test.
    @State private var trial = ""
    /// Manually typed text is not considered a test: we are waiting for a successful one
    /// insertion that occurred after entering the last step.
    @State private var trialStartCount = 0
    @State private var showAccessibilityRepairConfirmation = false
    @FocusState private var trialFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Alignment is set explicitly. Without it, a step that has none
            // an element that extends in breadth (for example, “Recognition model”, when
            // the model is already ready and there is no loading indicator), compressed to width
            // of your text and moved to the center of the window - and the neighboring steps
            // stood on the left edge. The same master looked assembled from
            // two different ones.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 8)
                // Each step is its own page: forward it slides left, back it
                // slides right — the same paths in both directions. With
                // Reduce Motion the content swaps instantly, no sliding.
                .id(step)
                .transition(
                    reduceMotion
                        ? .identity
                        : .push(from: movingForward ? .trailing : .leading)
                )

            // Whitespace separates the footer; a hairline here read as a
            // form's edge inside a window that should feel like one surface.
            VStack(spacing: 6) {
                ZStack {
                    // Dots hug the window center, not the neighboring buttons:
                    // without the ZStack, "Back" disappearing on the first step
                    // would shift them.
                    OnboardingProgressDots(step: step)

                    HStack {
                        if step.hasPrevious {
                            Button("Back") { back() }
                                .accessibilityHint("Go back to step \(step.rawValue)")
                                .disabled(isDictationBusy)
                        }
                        Spacer()
                        nextButton
                    }
                    .controlSize(.large)
                }

                // Why the button is disabled. Without this line a person sees a dead
                // “Next” doesn’t even know what is expected of him, but for the blind
                // the installation simply ends here.
                //
                // The line is always there, even empty: otherwise its appearance was shifted
                // the footer with the buttons is up, and the content area is down.
                // The step where the permit had just been issued was twitching entirely.
                Text(navigationBlockReason ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityHidden(navigationBlockReason == nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        // The combined setup step contains three cards and every model state,
        // including repair and download progress. Keep enough vertical room
        // for those controls without making the first-run window feel large.
        .frame(width: 600, height: 660)
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

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .setup: setup
        case .tryIt: tryIt
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            // The product crest. A plain system symbol in an accent circle —
            // like macOS's own setup assistants; deliberately no glass here:
            // Liquid Glass is the control layer, not content decoration.
            ZStack {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 76, height: 76)
                heroGlyph
            }
            .shadow(color: Color.accentColor.opacity(0.30), radius: 16, y: 6)
            .accessibilityHidden(true)

            Text("Dictation that stays on your Mac")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("Hold a key, speak, let go — the text appears at your cursor. In any app.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)

            // Fixed, not a Spacer: three flexible spacers would split the
            // leftover height evenly and blow this gap wide open.
            VStack(alignment: .leading, spacing: 14) {
                OnboardingFeatureRow(
                    symbol: "airplane",
                    title: "Works on a plane",
                    text: "Speech is recognized by a model on your disk. No internet needed."
                )
                OnboardingFeatureRow(
                    // An open lock reads as “unprotected” — the opposite.
                    symbol: "hand.raised",
                    title: "Nothing leaves this Mac",
                    text: "No accounts, no analytics, no reports. The code is open — you can check."
                )
                OnboardingFeatureRow(
                    symbol: "arrow.down.circle",
                    title: "Network, only on your terms",
                    text: "Used once to download the model, plus a small daily update check you can turn off."
                )
            }
            .frame(width: 420, alignment: .leading)
            .padding(.top, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// The microphone on the crest breathes — barely, like an invitation to
    /// speak. Reduce Motion and macOS 14 get a calm static symbol.
    @ViewBuilder
    private var heroGlyph: some View {
        let glyph = Image(systemName: "mic.fill")
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(.white)
        if #available(macOS 15.0, *), !reduceMotion {
            glyph.symbolEffect(.breathe, options: .repeat(.continuous))
        } else {
            glyph
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepHeader(
                symbol: "checklist",
                title: "Set up OpenRamble",
                subtitle: "One download, two permissions — speech never leaves this Mac."
            )

            VStack(spacing: 10) {
                // The model goes first: the 586 MB download runs while the
                // person makes the System Settings round-trips below it.
                VStack(alignment: .leading, spacing: 8) {
                    Label("Speech model", systemImage: "waveform")
                        .font(.headline)
                    ModelStatusView(
                        status: ModelStatus.make(
                            state: state.modelState,
                            preparation: state.enginePreparation,
                            place: .onboarding,
                            downloadMegabytes: state.remainingDownloadMegabytes,
                            isEngineReady: state.isEngineReady
                        ),
                        install: state.installModel,
                        cancel: state.cancelModelInstall,
                        delete: state.deleteModel
                    )
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))

                OnboardingPermission(
                    status: PermissionStatus(
                        title: "Microphone",
                        detail: "Hears you only while you hold the dictation key.",
                        granted: state.microphoneGranted
                    ),
                    action: state.requestMicrophone
                )
                OnboardingPermission(
                    status: PermissionStatus.accessibility(
                        state: state.accessibilityState,
                        detail: "Notices your dictation key and types the finished text at your cursor.",
                    ),
                    action: performAccessibilityAction
                )
            }

            if needsAccessibilityRepair {
                HStack {
                    Button("Show the app in Finder") {
                        state.revealApplicationForAccessibility()
                    }
                    Button("Open System Settings") {
                        state.openAccessibilitySettings()
                    }
                }
                .font(.caption)
            }

            Text("Input Monitoring is not needed. Accessibility is used only for the dictation key and for inserting finished text.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
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

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingStepHeader(
                symbol: "keyboard",
                title: "Try it",
                subtitle: "Hold \(state.hotkey.title), say a few words, let go — the text lands in the field below."
            )

            Picker("Dictation key", selection: $state.hotkey) {
                ForEach(DictationHotkey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("The key you hold down while dictating")
            .disabled(isDictationBusy)

            if let warning = state.hotkeyWarning {
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

            // Sample field. Present, with variable text: it used to be
            // tied to a constant, and what was dictated did not appear in it
            // never - the first attempt looked like nothing
            // works. The cursor is placed here by itself, otherwise the text will go into that window
            // which was ahead before onboarding.
            TextEditor(text: $trial)
                .frame(height: 90)
                .focused($trialFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .contentSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onAppear { trialFocused = true }
                .accessibilityLabel("Trial dictation field")

            // Color goes to the dot, not the words: red text reads as an
            // error, and here everything goes as intended.
            if state.dictationState == .listening {
                HStack(spacing: 8) {
                    Circle()
                        .fill(StatusColorRole.recording.color)
                        .frame(width: 8, height: 8)
                    Text("Listening…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording")
            }

            if trialSucceeded {
                Label("Done — dictation works", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(StatusColorRole.success.color)
                // “Done” closes the window, and the app has no Dock icon: say
                // where it lives, or the person loses it right here.
                Text("OpenRamble lives in your menu bar at the top of the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Button("Skip the try-out") { finishOnboarding() }
                        .buttonStyle(.borderless)
                        .disabled(isDictationBusy)
                        .accessibilityHint(
                            isDictationBusy ? "Finish or cancel the current dictation first" : ""
                        )
                    // The escape hatch: while dictation runs, Back, Next and
                    // Skip are all disabled — without this button a stuck
                    // trial locks the whole window.
                    if isDictationBusy {
                        Button("Cancel Dictation") { state.cancelCurrentDictation() }
                            .buttonStyle(.bordered)
                            .accessibilityHint("Stops the current dictation so you can continue setup.")
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Navigation

    private var nextButton: some View {
        Button(step.nextButtonTitle) {
            if step.isLast {
                finishOnboarding()
            } else {
                forward()
            }
        }
        // Default button: Return takes the master forward. Previously the main thing
        // the action of the entire installation was not accessible from the keyboard - Return is not
        // did nothing, and it was impossible to walk the setup without a mouse. On the last
        // in the step the focus is on the sample field, and Return goes to the field, not the button.
        .keyboardShortcut(.defaultAction)
        .disabled(navigationBlockReason != nil)
        .accessibilityHint(navigationBlockReason ?? "")
        .prominentActionButtonStyle()
    }

    private var navigationBlockReason: String? {
        isDictationBusy ? "Finish or cancel the current dictation first." : blockReason
    }

    private var blockReason: String? {
        OnboardingGate.blockReason(
            step: step,
            microphoneGranted: state.microphoneGranted,
            accessibilityGranted: state.accessibilityGranted,
            modelState: state.modelState,
            engineReady: state.isEngineReady,
            trialSucceeded: trialSucceeded
        )
    }

    private var trialSucceeded: Bool {
        state.successfulDictationCount > trialStartCount
            && !trial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isDictationBusy: Bool {
        switch state.dictationState {
        case .preparing, .listening, .transcribing, .inserting: true
        case .idle: false
        }
    }

    private func forward() {
        guard let next = step.next else { return }
        if next == .tryIt { trialStartCount = state.successfulDictationCount }
        movingForward = true
        withAnimation(stepTransition) { step = next }
    }

    private func back() {
        guard !isDictationBusy else { return }
        guard let previous = step.previous else { return }
        movingForward = false
        withAnimation(stepTransition) { step = previous }
    }

    /// `nil` - transition without animation, instant content change.
    private var stepTransition: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    private func finishOnboarding() {
        guard !isDictationBusy else { return }
        onFinish()
        // The window closes here. Otherwise the screen would remain blank
        // frame after configuration is complete.
        dismiss()
    }
}

/// Step header: symbol, title, explanation — one drawing for all steps,
/// centered like macOS's own assistants.
private struct OnboardingStepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Progress dots. The current step is a stretched capsule, like in macOS's
/// own assistants.
///
/// For VoiceOver it is one element with the words "Step 2 of 3": separate
/// dots mean nothing by ear.
private struct OnboardingProgressDots: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { candidate in
                Capsule()
                    .fill(candidate == step ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: candidate == step ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.progressAccessibilityLabel)
        .help(step.progressText)
    }
}

/// Value list item in the first step: a short claim in the person's favor,
/// then the fact that backs it.
///
/// The icon is in a fixed-width column. Otherwise, the column width is set
/// by the glyph itself, and glyph widths differ: the text of the third row
/// started a few points to the right of the first two, and the left edge of
/// the list went torn.
private struct OnboardingFeatureRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingPermission: View {
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: status.granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status.granted ? StatusColorRole.success.color : .secondary)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.headline)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Title, explanation and checkmark are about the same thing. Separately
            // VoiceOver reads them as three elements, and "issued" hangs without
            // owner.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityValue(status.accessibilityValue)

            Spacer()

            if let title = status.actionTitle {
                Button(title, action: action)
                    .buttonStyle(.bordered)
                    .accessibilityLabel(status.actionAccessibilityLabel ?? title)
            }
        }
        .padding(14)
        .contentSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
