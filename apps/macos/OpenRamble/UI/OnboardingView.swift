import AppKit
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

    @State private var step: OnboardingStep
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
    /// The dictation key, heard through this window alone: no permission is
    /// needed for the drawn key to answer the real one.
    @StateObject private var keyEcho = KeyEcho()

    /// - Parameter step: where to open. `nil` picks the first step that still
    ///   has something to do.
    init(state: AppState, step: OnboardingStep? = nil, onFinish: @escaping () -> Void) {
        self.state = state
        self.onFinish = onFinish
        _step = State(initialValue: step ?? OnboardingStep.first(
            microphoneGranted: state.microphoneGranted,
            accessibilityGranted: state.accessibilityGranted
        ))
    }

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
                            Button(L10n.tr("Back")) { back() }
                                .accessibilityHint(L10n.tr("Go back to step %@", String(describing: step.rawValue)))
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
        .frame(width: 600, height: 640)
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

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .setup: setup
        case .tryIt: tryIt
        }
    }

    // MARK: - Steps

    /// One thing on the screen: the key. It goes down when the real one
    /// does, so the first thing a person learns is where their finger goes.
    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Text(L10n.tr("Hold a key, speak, let go."))
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(L10n.tr("The words appear at your cursor, in any app."))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            KeyCap(title: state.hotkey.shortTitle, size: .hero, isPressed: keyEcho.isDown)
                .padding(.top, 44)

            Text(keyEcho.wasPressed
                ? L10n.tr("That is your dictation key.")
                : L10n.tr("Press %@ to find it.", String(describing: state.hotkey.title)))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text(PrivacySentence.text)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("No account. Free and open source."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentBlock()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            let state = state
            keyEcho.start { [weak state] in state?.hotkey ?? SettingsDefaults.hotkey }
        }
        .onDisappear { keyEcho.stop() }
    }

    /// Three blocks, one per thing that is needed. Each says what it is for
    /// and turns green when it is done.
    private var setup: some View {
        VStack(alignment: .leading, spacing: GlassTokens.Block.gap) {
            OnboardingStepHeader(
                title: L10n.tr("Set up OpenRamble"),
                subtitle: L10n.tr("One download, two permissions — speech never leaves this Mac.")
            )
            .padding(.bottom, GlassTokens.Space.stack - GlassTokens.Block.gap)

            VStack(alignment: .leading, spacing: 10) {
                BlockLabel(L10n.tr("Speech model"))
                ModelStatusView(
                    status: modelCard,
                    install: state.installModel,
                    cancel: state.cancelModelInstall,
                    delete: state.deleteModel
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentBlock()

            OnboardingPermission(
                status: PermissionStatus(
                    title: L10n.tr("Microphone"),
                    detail: L10n.tr("Hears your voice during dictation and recordings you start."),
                    granted: state.microphoneGranted
                ),
                action: state.requestMicrophone
            )
            OnboardingPermission(
                status: PermissionStatus.accessibility(
                    state: state.accessibilityState,
                    detail: L10n.tr("Notices your dictation key and types the finished text at your cursor."),
                ),
                action: performAccessibilityAction
            ) {
                if AccessibilityRepairLink.isShown(
                    state: state.accessibilityState,
                    returnedWithoutGrant: state.accessibilityReturnedWithoutGrant
                ) {
                    AccessibilityRepairLinkButton(modelState: state.modelState) {
                        showAccessibilityRepairConfirmation = true
                    }
                }
            }

            if needsAccessibilityRepair {
                HStack {
                    Button(L10n.tr("Show the app in Finder")) {
                        state.revealApplicationForAccessibility()
                    }
                    Button(L10n.tr("Open System Settings")) {
                        state.openAccessibilitySettings()
                    }
                }
                .font(.caption)
            }

            Text(L10n.tr("Accessibility is used only to notice your dictation key and insert finished text. Other keystrokes are never logged or stored. Input Monitoring is not needed."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, GlassTokens.Space.stack)
                .padding(.top, GlassTokens.Space.tight)

            Spacer(minLength: 0)
        }
    }

    /// What the app has to say about the model, written once for both steps
    /// that show it. The setup step draws the whole card; the try-out step
    /// draws its one-line form while there is something to say.
    private var modelCard: ModelStatus {
        ModelStatus.make(
            state: state.modelState,
            preparation: state.enginePreparation,
            place: .onboarding,
            downloadMegabytes: state.remainingDownloadMegabytes,
            isEngineReady: state.isEngineReady,
            isPreparingEngine: state.isPreparingEngine,
            hasMirror: state.modelHasMirror
        )
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

    /// Teach by doing: the key on the screen goes down with the real one,
    /// and the words land in a note that belongs to this window.
    private var tryIt: some View {
        VStack(alignment: .leading, spacing: GlassTokens.Space.stack) {
            OnboardingStepHeader(
                title: L10n.tr("Hold %@ and say something.", String(describing: state.hotkey.shortTitle)),
                subtitle: L10n.tr("Let go when you are done. The words land in the note below.")
            )

            if let line = modelCard.setupLine {
                HStack(spacing: 8) {
                    if state.isPreparingEngine {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(modelCard.announcement)
            }

            // The note: a page of the person's own, so the first take needs
            // no other app to land in.
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $trial)
                    .font(.system(size: 17))
                    .frame(height: 104)
                    .focused($trialFocused)
                    .scrollContentBackground(.hidden)
                    .onAppear { trialFocused = true }
                    .accessibilityLabel(L10n.tr("Trial dictation field"))
                    .overlay(alignment: .topLeading) {
                        if trial.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr("Try saying"))
                                    .font(.system(size: 12))
                                Text(OnboardingStep.tryOutSuggestion())
                                    .font(.system(size: 17))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityElement(children: .combine)
                        }
                    }
            }
            .padding(14)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: GlassTokens.Radius.surface, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: GlassTokens.Radius.surface, style: .continuous)
                    .strokeBorder(
                        trialSucceeded
                            ? StatusColorRole.success.color
                            : Color.primary.opacity(0.14),
                        lineWidth: trialSucceeded ? 2 : 1
                    )
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: trialSucceeded)

            HStack(alignment: .center, spacing: GlassTokens.Space.stack) {
                DictationKeyMenu(
                    hotkey: $state.hotkey,
                    isPressed: isListening && !state.isHandsFreeActive
                )
                .disabled(isDictationBusy)

                VStack(alignment: .leading, spacing: 4) {
                    if trialSucceeded {
                        HStack(spacing: 8) {
                            StateGlyphView(glyph: .pasted)
                            Text(L10n.tr("Done — dictation works"))
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .accessibilityElement(children: .combine)
                        Text(L10n.tr("OpenRamble lives in your menu bar at the top of the screen. Settings can move it to the Dock instead — never to neither."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isListening {
                        HStack(spacing: 8) {
                            StateGlyphView(glyph: .listening)
                            Text(L10n.tr("Listening"))
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.tr("Recording"))
                    } else if let warning = state.hotkeyWarning {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            StateGlyphView(glyph: .attention, size: 12)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                            Text(warning)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(L10n.tr("Key warning. %@", String(describing: warning)))
                    } else {
                        Text(L10n.tr("Hold to talk. Double-press for hands-free."))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("Click the key to choose another."))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: KeyCap.Size.large.height + KeyCap.Size.large.travel)

            if !trialSucceeded {
                HStack(spacing: 12) {
                    Button(L10n.tr("Skip the try-out")) { finishOnboarding() }
                        .buttonStyle(.borderless)
                        .disabled(isDictationBusy)
                        .accessibilityHint(
                            isDictationBusy ? L10n.tr("Finish or cancel the current dictation first") : ""
                        )
                    if isDictationBusy {
                        Button(L10n.tr("Cancel Dictation")) { state.cancelCurrentDictation() }
                            .buttonStyle(.bordered)
                            .accessibilityHint(L10n.tr("Stops the current dictation so you can continue setup."))
                    }
                }
                .font(.system(size: 12))
            }

            Spacer(minLength: 0)
        }
    }

    private var isListening: Bool {
        state.dictationState == .preparing || state.dictationState == .listening
    }

    // MARK: - Navigation

    private var nextButton: some View {
        Button(step.continueTitle(
            modelState: state.modelState,
            downloadMegabytes: state.remainingDownloadMegabytes
        )) {
            if step.isLast {
                finishOnboarding()
            } else {
                if step.downloadsOnContinue(modelState: state.modelState) {
                    state.installModel()
                }
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
        OnboardingGate.blockReason(
            step: step,
            conditions: OnboardingConditions(state: state, trialSucceeded: trialSucceeded)
        )
    }

    private var trialSucceeded: Bool {
        state.successfulDictationCount > trialStartCount
            && !trial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isDictationBusy: Bool { state.dictationState.isBusy }

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

extension OnboardingConditions {
    /// The only place onboarding reads its facts off the running app.
    ///
    /// One reader, on purpose. The gate is pure and its tests are cheap, but a
    /// test that assembles the arguments itself is checking a screen of its own
    /// invention: the engine requirement that stranded 0.8.1 and 0.8.2 could be
    /// put back with a defaulted argument, and every test that filled in its own
    /// arguments would have stayed green while the app deadlocked. A new fact
    /// has to be added to `OnboardingConditions` and picked up here — where the
    /// tests are standing too.
    @MainActor
    init(state: AppState, trialSucceeded: Bool) {
        self.init(
            microphoneGranted: state.microphoneGranted,
            accessibilityGranted: state.accessibilityGranted,
            modelState: state.modelState,
            isDictationBusy: state.dictationState.isBusy,
            trialSucceeded: trialSucceeded,
            // Asked of the same type the key press asks, with the same
            // arguments. Two authors for one sentence is how the setup screen
            // came to contradict the card standing above it.
            dictationRefusal: DictationReadiness.reason(
                accessibilityGranted: state.accessibilityGranted,
                microphoneGranted: state.microphoneGranted,
                modelState: state.modelState,
                isEngineReady: state.isEngineReady,
                engineWasReadyBefore: state.hasEngineBeenReady
            )
        )
    }
}

/// Step header: what to do, and one sentence about it. Centered like
/// macOS's own assistants.
private struct OnboardingStepHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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

/// A permission as a block: what it is for, and the one button that grants
/// it. Granted, it turns green and the button goes.
private struct OnboardingPermission<Secondary: View>: View {
    let status: PermissionStatus
    let action: () -> Void
    @ViewBuilder var secondary: Secondary

    init(
        status: PermissionStatus,
        action: @escaping () -> Void,
        @ViewBuilder secondary: () -> Secondary = { EmptyView() }
    ) {
        self.status = status
        self.action = action
        self.secondary = secondary()
    }

    var body: some View {
        HStack(spacing: 12) {
            StateGlyphView(glyph: status.granted ? .pasted : .silent, size: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(status.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityValue(status.accessibilityValue)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if let title = status.actionTitle {
                    Button(title, action: action)
                        .buttonStyle(.bordered)
                        .accessibilityLabel(status.actionAccessibilityLabel ?? title)
                }
                secondary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentBlock(padding: GlassTokens.Space.stack)
    }
}
