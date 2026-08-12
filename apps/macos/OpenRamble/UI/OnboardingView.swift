import DictationCore
import LocalASR
import SwiftUI

/// First launch: from installation to the first dictated phrase.
///
/// Three focused steps take a person from installation to a verified first dictation.
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
                .padding(32)
                // Each step is its own page: forward it slides left, back it
                // slides right — the same paths in both directions. With
                // Reduce Motion the content swaps instantly, no sliding.
                .id(step)
                .transition(
                    reduceMotion
                        ? .identity
                        : .push(from: movingForward ? .trailing : .leading)
                )

            Divider()

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
            .padding()
        }
        // The combined setup step contains two permission rows and every model
        // state, including repair and download progress. Keep enough vertical
        // room for those controls without making the first-run window feel large.
        .frame(width: 560, height: 560)
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
            .accessibilityHidden(true)

            Text("Dictation that stays on your Mac")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("Press a key, speak, release — the text appears at your cursor. In any app.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 12) {
                OnboardingPoint(
                    symbol: "airplane",
                    text: "Speech is recognized by a model on your disk. Works on a plane."
                )
                OnboardingPoint(
                    symbol: "arrow.down.circle",
                    text: "Network access is limited to model downloads and a small daily update check that you can turn off."
                )
                OnboardingPoint(
                    // An open lock is read as “unprotected” - exactly the opposite.
                    symbol: "eye.slash",
                    text: "No accounts, no analytics, no reports. The code is open — you can check."
                )
            }
            .font(.callout)

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
        VStack(alignment: .leading, spacing: 14) {
            OnboardingStepHeader(
                symbol: "lock.shield",
                title: "Set up OpenRamble",
                subtitle: "Two permissions and one local model. Speech never leaves this Mac."
            )

            VStack(spacing: 10) {
                OnboardingPermission(
                    status: PermissionStatus(
                        title: "Microphone",
                        detail: "To hear your speech.",
                        granted: state.microphoneGranted
                    ),
                    action: state.requestMicrophone
                )
                OnboardingPermission(
                    status: PermissionStatus.accessibility(
                        state: state.accessibilityState,
                        detail: "To hear the hotkey and insert the finished text.",
                    ),
                    action: performAccessibilityAction
                )

                VStack(alignment: .leading, spacing: 8) {
                    Label("Offline recognition", systemImage: "waveform")
                        .font(.headline)
                    ModelStatusView(
                        status: ModelStatus.make(
                            state: state.modelState,
                            isPreparingEngine: state.isPreparingEngine,
                            preparation: state.enginePreparation,
                            place: .onboarding,
                            downloadMegabytes: state.remainingDownloadMegabytes
                        ),
                        install: state.installModel,
                        cancel: state.cancelModelInstall,
                        delete: state.deleteModel
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

            Text("Input Monitoring is not needed. Accessibility is used only for the chosen hotkey and finished-text insertion.")
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
                symbol: "mic",
                title: "Try it",
                subtitle: nil
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
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Key warning. \(warning)")
            }

            Text("Hold \(state.hotkey.title), say something, and release. The text will appear in the field below.")
                .foregroundStyle(.secondary)

            // Sample field. Present, with variable text: it used to be
            // tied to a constant, and what was dictated did not appear in it
            // never - the first attempt looked like nothing
            // works. The cursor is placed here by itself, otherwise the text will go into that window
            // which was ahead before onboarding.
            TextEditor(text: $trial)
                .frame(height: 90)
                .focused($trialFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onAppear { trialFocused = true }
                .accessibilityLabel("Trial dictation field")

            // Color goes to the dot, not the words: red text reads as an
            // error, and here everything goes as intended.
            if state.dictationState == .listening {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Listening…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording")
            }

            if trialSucceeded {
                Label("Done — dictation works", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Skip the try-out") { finishOnboarding() }
                    .buttonStyle(.link)
                    .disabled(isDictationBusy)
                    .accessibilityHint(
                        isDictationBusy ? "Finish or cancel the current dictation first" : ""
                    )
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

/// Step header: symbol, title, explanation — one drawing for all steps.
private struct OnboardingStepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

/// Value list item in the first step.
///
/// The icon is in a fixed-width column. Otherwise, the column width is set by yourself
/// glyph, and `eye.slash` has it wider than `airplane`: text of the third paragraph
/// started a few dots to the right of the first two, and the left edge of the list went
/// torn.
private struct OnboardingPoint: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
                .frame(width: 20, alignment: .center)
        }
    }
}

private struct OnboardingPermission: View {
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: status.granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status.granted ? .green : .secondary)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
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
                    .accessibilityLabel(status.actionAccessibilityLabel ?? title)
            }
        }
        .padding(12)
        .contentSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
