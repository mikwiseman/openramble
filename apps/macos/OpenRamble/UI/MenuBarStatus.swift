import DictationCore
import LocalASR
import SwiftUI

/// What the icon is signalling right now.
enum MenuBarActivity: Equatable {
    case hidden
    case recording
    case working
}

/// The dot over the brand mark. One shape, one meaning per color — see
/// `StatusColorRole`: red = the microphone is capturing, blue = working on
/// speech, orange = something waits for the person.
enum MenuBarBadge: Equatable {
    case hidden
    case recording
    case working
    case attention
}

/// The menu bar identity and what it says about the current app state.
///
/// The icon is the only permanent presence of the application on the screen.
/// A picture without a description does not exist at all for a blind person,
/// so the brand mark is paired with a state-specific accessibility label below.
enum MenuBarStatus {
    /// The brand mark shown in every state.
    ///
    /// macOS already adds its own microphone privacy indicator while recording.
    /// Swapping this mark for another microphone made one app look like two
    /// microphone tools. The dot, menu copy and accessibility label report
    /// state without replacing the app identity.
    static let brandIconName = "BrandIconMenuBar"

    /// `isRecordingMeeting`: a meeting or voice note is being recorded. That
    /// is the microphone capturing, so it wears the same red as dictation;
    /// dictation's own work outranks it for the seconds it lasts.
    static func activity(state: DictationState, isRecordingMeeting: Bool = false) -> MenuBarActivity {
        switch state {
        // No dot until audio is actually being captured: the red dot must
        // never lie about the microphone, and the overlay already answers the
        // key press instantly.
        case .preparing: return isRecordingMeeting ? .recording : .hidden
        case .listening: return .recording
        case .transcribing, .inserting: return .working
        case .idle: return isRecordingMeeting ? .recording : .hidden
        }
    }

    /// The menu's line about a running recording. Computed when the menu is
    /// built — no clock lives in the menu bar.
    static func recordingLine(
        isPaused: Bool,
        duration: TimeInterval,
        isDegraded: Bool = false,
        microphoneMissing: Bool = false
    ) -> String {
        let line = "\(isPaused ? L10n.tr("Paused") : L10n.tr("Recording")) — \(RecordingTime.clock(duration))"
        guard !isPaused else { return line }
        if microphoneMissing, isDegraded { return line + L10n.tr(" — nothing arriving") }
        if microphoneMissing { return line + L10n.tr(" — not your microphone") }
        if isDegraded { return line + L10n.tr(" — only your microphone") }
        return line
    }

    /// Recording and working stay distinguishable without color through the
    /// accessibility label and the menu's first line; the two dots also differ
    /// strongly in luminance for color-blind users.
    /// `recordingIsDegraded`: a meeting whose other side is not arriving. Orange
    /// is already the app's word for "something waits for you and your work is
    /// preserved" — which is exactly this: the audio is safe, half of it is
    /// missing, and one change can still fix the rest of the meeting. It
    /// outranks the steady red because the red would say everything is fine.
    static func badge(
        activity: MenuBarActivity,
        needsAttention: Bool = false,
        recordingIsDegraded: Bool = false
    ) -> MenuBarBadge {
        if recordingIsDegraded, activity != .working { return .attention }
        switch activity {
        case .recording: return .recording
        case .working: return .working
        case .hidden: return needsAttention ? .attention : .hidden
        }
    }

    /// Does setup wait on the person right now?
    ///
    /// True only for states a click can advance: a permission to grant, a
    /// download to start, a repair to confirm. Work in progress — downloading,
    /// verifying, deleting, repairing, engine warm-up — is the app's job, and
    /// showing "attention" for it would train people to ignore the dot.
    static func setupNeedsUserAction(
        accessibilityState: AccessibilityPermissionState,
        microphoneGranted: Bool,
        modelState: ModelState
    ) -> Bool {
        if !microphoneGranted { return true }
        switch accessibilityState {
        case .denied, .waitingForSettings, .restartRequired, .repairRequired, .failed:
            return true
        case .repairing, .granted:
            break
        }
        switch modelState {
        case .notInstalled, .repairRequired, .failed:
            return true
        case .downloading, .verifying, .deleting, .ready:
            return false
        }
    }

    /// Icon description. Starts with the application name: there are many
    /// icons in the menu bar, and "recording in progress" says nothing
    /// without the owner.
    static func accessibilityLabel(
        state: DictationState,
        isDictationReady: Bool,
        hasRecoveredWork: Bool = false,
        isRecordingMeeting: Bool = false,
        recordingIsDegraded: Bool = false,
        microphoneMissing: Bool = false
    ) -> String {
        if isRecordingMeeting, microphoneMissing {
            return L10n.tr("OpenRamble: recording — your microphone isn't being captured")
        }
        if isRecordingMeeting, recordingIsDegraded {
            return L10n.tr("OpenRamble: recording — the other side isn't being captured")
        }
        switch state {
        case .listening: return L10n.tr("OpenRamble: recording")
        case .transcribing: return L10n.tr("OpenRamble: transcribing speech")
        case .inserting: return L10n.tr("OpenRamble: inserting text")
        case .preparing: return L10n.tr("OpenRamble: turning on the microphone")
        case .idle:
            if isRecordingMeeting {
                return L10n.tr("OpenRamble: recording")
            }
            // The dot on the icon must also sound for VoiceOver: a picture
            // without words does not exist for the blind.
            if hasRecoveredWork {
                return L10n.tr("OpenRamble: last dictation needs attention — open the menu")
            }
            return isDictationReady
                ? L10n.tr("OpenRamble: ready to dictate")
                : L10n.tr("OpenRamble: setup needed")
        }
    }

    /// The first line of the menu is also an explanation of what to do.
    ///
    /// It talks about unfinished work before it talks about the key. The
    /// dictation panel is a toast: it lives four seconds and leaves, so the
    /// lasting explanation has to live somewhere permanent — the menu. The
    /// "Insert Last Dictation" item sits right below this line.
    static func statusLine(
        state: DictationState,
        isDictationReady: Bool,
        isHandsFreeActive: Bool,
        hotkeyTitle: String,
        hasRecoveredText: Bool = false
    ) -> String {
        switch state {
        case .idle:
            if hasRecoveredText {
                return L10n.tr("Last dictation wasn't inserted")
            }
            // The idle line teaches the one gesture the app has. "Ready"
            // alone told a new person nothing about what to do next.
            return isDictationReady
                ? L10n.tr("Ready — hold %@ and speak", String(describing: hotkeyTitle))
                : L10n.tr("Setup needed")
        case .preparing: return L10n.tr("Turning on the microphone…")
        case .listening:
            // In hands-free mode the key is released and recording continues.
            // Not saying so leaves the person with a live microphone and the
            // belief that it is already off.
            return isHandsFreeActive
                ? L10n.tr("Listening — press %@ to finish", String(describing: hotkeyTitle))
                : L10n.tr("Listening")
        case .transcribing: return L10n.tr("Transcribing…")
        case .inserting: return L10n.tr("Inserting…")
        }
    }
}
