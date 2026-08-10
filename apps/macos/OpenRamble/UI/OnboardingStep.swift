import LocalASR

/// First launch steps and rules for transition between them.
///
/// A separate type, and not a field inside the view: here it is decided whether a new one will arrive
/// the user reaches a working product or hits a disabled button.
/// You need to check this with a table, and not with your eyes on a live screen - the screen in
/// there may be no verification at all.
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case permissions
    case model
    case tryIt

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    /// Is there somewhere to return?
    ///
    /// At the first step there is no “Back” button: it would lead to nowhere, and the extinguished
    /// the button looks broken.
    var hasPrevious: Bool { previous != nil }

    var isLast: Bool { next == nil }

    /// Signature of the transition button.
    var nextButtonTitle: String { isLast ? "Done" : "Continue" }

    var progressText: String { "\(rawValue + 1) of \(Self.allCases.count)" }

    /// The same thing in words.
    ///
    /// "1 of 4" without the word "step" VoiceOver reads like a couple of numbers out of nowhere.
    var progressAccessibilityLabel: String {
        "Step \(rawValue + 1) of \(Self.allCases.count)"
    }
}

/// Does it allow a step further and, if not, why.
///
/// Reason is not decoration. An extinguished button leaves a person without explanation
/// guess what they want from him; for a blind person it is simply an “inaccessible button”
/// Next”, and this completes the installation.
enum OnboardingGate {
    /// `nil` - you can move on.
    static func blockReason(
        step: OnboardingStep,
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        modelState: ModelState,
        engineReady: Bool = true,
        trialSucceeded: Bool = true
    ) -> String? {
        switch step {
        case .welcome:
            return nil

        case .tryIt:
            return trialSucceeded
                ? nil
                : "Try dictation first, or press “Skip the try-out”."

        case .permissions:
            // We proceed further only when both permissions have been issued: next step
            // without them it won’t show anything, and the person will decide that everything is broken.
            switch (microphoneGranted, accessibilityGranted) {
            case (true, true): return nil
            case (false, false): return "Two permissions left to grant — Microphone and Accessibility."
            case (false, true): return "Microphone is still needed."
            case (true, false): return "Accessibility is still needed."
            }

        case .model:
            switch modelState {
            case .ready: return engineReady ? nil : "Wait for the model to finish preparing for first use."
            case .notInstalled: return "Download the model first — without it there is nothing to recognize with."
            case .downloading: return "Wait for the download to finish."
            case .verifying: return "The download is being verified."
            case .repairRequired: return "The model is damaged. Redownload it explicitly."
            case .failed: return "The download failed. Try again."
            case .deleting: return "The model is being deleted."
            }
        }
    }

    static func canAdvance(
        step: OnboardingStep,
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        modelState: ModelState,
        engineReady: Bool = true,
        trialSucceeded: Bool = true
    ) -> Bool {
        blockReason(
            step: step,
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
            modelState: modelState,
            engineReady: engineReady,
            trialSucceeded: trialSucceeded
        ) == nil
    }
}
