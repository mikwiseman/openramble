import LocalASR

/// Why pressing a key now won't start anything.
///
/// The kernel rejects the start silently - and does the right thing: it has neither a screen nor
/// words. But for a person, silence is indistinguishable from a breakdown. This is most painful in
/// warm-up window immediately after installation: he just did everything right,
/// presses a key, and nothing happens - no sound, no panel, no explanation.
///
/// By a separate type, not by branches within `AppState`: the set of reasons is checked
/// with a table, and not by pressing a live key on a live microphone.
enum DictationReadiness {
    /// `nil` - can be dictated.
    ///
    /// The order is the same as the onboarding order: first permissions, then
    /// model, then warming up. A person is called the first thing that holds him, not
    /// all three at once - a list of three items in the panel for four seconds does not
    /// read.
    static func reason(
        accessibilityGranted: Bool,
        microphoneGranted: Bool,
        modelState: ModelState,
        isEngineReady: Bool,
        engineWasReadyBefore: Bool = false
    ) -> String? {
        guard accessibilityGranted else {
            return "Dictation needs Accessibility access. Open Settings → General → Permissions."
        }
        guard microphoneGranted else {
            return "Dictation needs microphone access. Open Settings → General → Permissions."
        }

        switch modelState {
        case .notInstalled:
            return "The recognition model isn't downloaded yet. Open Settings → Model."
        case .downloading:
            return "The recognition model is still downloading."
        case .verifying:
            return "The downloaded model is still being verified."
        case .deleting:
            return "The recognition model is being deleted."
        case .repairRequired, .failed:
            return "The recognition model needs repair. Open Settings → Model."
        case .ready:
            break
        }

        guard isEngineReady || engineWasReadyBefore else {
            // The most offensive case: everything is installed, everything is issued, and still
            // silence. We name the deadline - otherwise it’s unclear whether to wait a second or
            // restart the application.
            //
            // Only the FIRST warm-up blocks. Once the engine has ever been
            // ready, an unloaded engine (residency gave its memory back) must
            // not stop the press: recording starts instantly and the reload
            // rides under the voice.
            return "The model is getting ready for this Mac — usually 20–40 seconds, and only once."
        }

        return nil
    }
}
