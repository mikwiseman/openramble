import LocalASR

/// First launch steps and rules for transition between them.
///
/// A separate type, and not a field inside the view: here it is decided whether a new one will arrive
/// the user reaches a working product or hits a disabled button.
/// You need to check this with a table, and not with your eyes on a live screen - the screen in
/// there may be no verification at all.
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case setup
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
    /// "1 of 3" without the word "step" VoiceOver reads like a couple of numbers out of nowhere.
    var progressAccessibilityLabel: String {
        "Step \(rawValue + 1) of \(Self.allCases.count)"
    }
}

/// Everything onboarding is allowed to wait for, in one value.
///
/// The list is the whole safety property, so it is written down as a type
/// rather than as a parameter list that each caller fills in for itself. A
/// screen may only be held by a fact that is the person's to change — two
/// permissions, a download they start — or by work genuinely in motion that
/// ends on its own. A loaded engine is neither: residency gives its memory back
/// whenever the Mac asks, and that engine's own comeback is the next key press,
/// which nobody makes while this very screen is holding them here. It was on
/// this list until 0.8.2, and the result was a setup screen that said "Model
/// ready" and "Getting the model ready…" at the same instant and never let go
/// until the app was quit.
///
/// Anything added here has to meet that test first — and it is read off the
/// running app in exactly one place, `init(state:trialSucceeded:)`, so the
/// tests that hold this bar cannot be looking at a different screen from the one
/// the app draws.
struct OnboardingConditions {
    var microphoneGranted: Bool
    var accessibilityGranted: Bool
    var modelState: ModelState
    /// A dictation started from the try-out step. It ends by itself or by the
    /// "Cancel Dictation" button that is on the same screen.
    var isDictationBusy: Bool = false
    var trialSucceeded: Bool = true
    /// Why a key press right now would be refused, in the words the press
    /// itself uses — `nil` when dictation can start.
    ///
    /// The one exception to the paragraph above, and it earns it by never
    /// disabling anything: it only ever replaces the try-out step's own
    /// sentence with a truer one. That step is already held by a trial that has
    /// not happened, and while the one-time compile runs it cannot happen —
    /// asking for it then is asking for something the app is refusing. There is
    /// no second opinion to drift, because this is the sentence the refused
    /// press itself shows (`DictationReadiness`).
    var dictationRefusal: String? = nil
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
        conditions: OnboardingConditions
    ) -> String? {
        // While a take is running, Back, Next and Skip are all disabled — this
        // is the sentence under all of them. It outranks the step's own reason
        // because it is the one thing the person can act on right now.
        if conditions.isDictationBusy {
            return "Finish or cancel the current dictation first."
        }

        switch step {
        case .welcome:
            return nil

        case .tryIt:
            if conditions.trialSucceeded { return nil }
            // This step asks for a key press, so it is held by whatever holds
            // that press. After a fresh install that is the one-time compile,
            // and for its twenty to forty seconds "try dictation first" asks
            // for something the app itself is refusing — the person holds the
            // key, nothing records, and the screen keeps asking. The compile
            // ends by itself and "Skip the try-out" is on the same screen, so
            // nothing here is a deadlock; it only has to be true.
            if let refusal = conditions.dictationRefusal { return refusal }
            return "Try dictation first, or press “Skip the try-out”."

        case .setup:
            // Permissions and the local model are one setup job. Keeping them on
            // separate pages created an almost empty “Model ready” step for existing
            // installs and made the shortest path feel longer than it is.
            switch (conditions.microphoneGranted, conditions.accessibilityGranted) {
            case (true, true): break
            case (false, false): return "Two permissions left to grant — Microphone and Accessibility."
            case (false, true): return "Microphone is still needed."
            case (true, false): return "Accessibility is still needed."
            }

            switch conditions.modelState {
            case .ready: return nil
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
        conditions: OnboardingConditions
    ) -> Bool {
        blockReason(step: step, conditions: conditions) == nil
    }
}
