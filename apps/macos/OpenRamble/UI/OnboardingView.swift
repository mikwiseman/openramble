import DictationCore
import LocalASR
import SwiftUI

/// First launch: from installation to the first dictated phrase.
///
/// The order of steps is chosen so that the model is loaded in the background while the person
/// reads and issues permissions - otherwise it would just look at the indicator.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// “Reduce Motion” in universal access. Transition between steps -
    /// decoration, and the person who disabled it should not get it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: OnboardingStep = .welcome
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

            Divider()

            VStack(spacing: 6) {
                HStack {
                    if step.hasPrevious {
                        Button("Back") { back() }
                            .accessibilityHint("Go back to step \(step.rawValue)")
                    }
                    Spacer()
                    Text(step.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(step.progressAccessibilityLabel)
                    Spacer()
                    nextButton
                }

                // Why the button is disabled. Without this line a person sees a dead
                // “Next” doesn’t even know what is expected of him, but for the blind
                // the installation simply ends here.
                //
                // The line is always there, even empty: otherwise its appearance was shifted
                // the footer with the buttons is up, and the content area is down.
                // The step where the permit had just been issued was twitching entirely.
                Text(blockReason ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityHidden(blockReason == nil)
            }
            .padding()
        }
        .frame(width: 560, height: 420)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictation that never sends your speech anywhere")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Press a key, speak, release — the text appears where your cursor was. In any app.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
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

            Spacer()
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up OpenRamble")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Two permissions and one local model. Speech never leaves this Mac.")
                .foregroundStyle(.secondary)

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
                .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Text("Try it")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Picker("Dictation key", selection: $state.hotkey) {
                ForEach(DictationHotkey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("The key you hold down while dictating")

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

            if state.dictationState == .listening {
                Label("Listening…", systemImage: "waveform")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Recording")
            }

            if trialSucceeded {
                Label("Done — dictation works", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Skip the try-out") { finishOnboarding() }
                    .buttonStyle(.link)
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
        .buttonStyle(.borderedProminent)
        // Default button: Return takes the master forward. Previously the main thing
        // the action of the entire installation was not accessible from the keyboard - Return is not
        // did nothing, and it was impossible to walk the setup without a mouse. On the last
        // in the step the focus is on the sample field, and Return goes to the field, not the button.
        .keyboardShortcut(.defaultAction)
        .disabled(blockReason != nil)
        .accessibilityHint(blockReason ?? "")
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

    private func forward() {
        guard let next = step.next else { return }
        if next == .tryIt { trialStartCount = state.successfulDictationCount }
        withAnimation(stepTransition) { step = next }
    }

    private func back() {
        guard let previous = step.previous else { return }
        withAnimation(stepTransition) { step = previous }
    }

    /// `nil` - transition without animation, instant content change.
    private var stepTransition: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    private func finishOnboarding() {
        onFinish()
        // The window closes here. Otherwise the screen would remain blank
        // frame after configuration is complete.
        dismiss()
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
        .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
