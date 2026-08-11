import DictationCore
import SwiftUI

enum MenuBarActivity: Equatable {
    case hidden
    case recording
    case processing
}

/// The menu bar identity and what it says about the current app state.
///
/// The icon is the only permanent presence of the application on the screen. Picture
/// without a description for a blind person does not exist at all, so the brand mark is
/// paired with a state-specific accessibility label below.
enum MenuBarStatus {
    /// The brand mark shown in every state.
    ///
    /// macOS already adds its own microphone privacy indicator while recording.
    /// Swapping this mark for another microphone made one app look like two
    /// microphone tools. The overlay, menu copy and accessibility label report
    /// recording, setup and recovery state without replacing the app identity.
    static let brandIconName = "BrandIconMenuBar"

    static func iconName(
        state: DictationState,
        isDictationReady: Bool,
        hasRecoveredWork: Bool = false
    ) -> String {
        brandIconName
    }

    static func activity(state: DictationState) -> MenuBarActivity {
        switch state {
        case .listening: return .recording
        case .transcribing, .inserting: return .processing
        case .idle, .preparing: return .hidden
        }
    }

    static func color(activity: MenuBarActivity) -> Color {
        switch activity {
        case .recording: return .red
        case .processing: return .blue
        case .hidden: return .clear
        }
    }

    /// Icon shortcut. Starts with the application name: there are many icons in the menu bar,
    /// and “recording in progress” says nothing without the owner.
    static func accessibilityLabel(
        state: DictationState,
        isDictationReady: Bool,
        hasRecoveredWork: Bool = false
    ) -> String {
        switch state {
        case .listening: return "OpenRamble: recording"
        case .transcribing: return "OpenRamble: transcribing speech"
        case .inserting: return "OpenRamble: inserting text"
        case .preparing: return "OpenRamble: turning on the microphone"
        case .idle:
            // The badge on the icon must also sound for VoiceOver: picture without
            // there are no words for the blind.
            if hasRecoveredWork {
                return "OpenRamble: last dictation needs attention — open the menu"
            }
            return isDictationReady
                ? "OpenRamble: ready to dictate"
                : "OpenRamble: setup needed"
        }
    }

    /// The first line of the menu is also an explanation of what to do.
    ///
    /// She talks about unfinished work before she talks about the key. Panel
    /// dictations - toast: she lives for four seconds and leaves, and that’s right,
    /// because there is nothing to close it with - it does not take focus and the close button is
    /// it doesn’t exist, and a fireproof window on top of someone else’s work would be worse than disaster,
    /// which it explains. So the explanation has to settle somewhere
    /// forever, and this place is the menu: the Retry/Copy items are right below the line.
    /// Previously, the “text not inserted” message would simply disappear, and the person who
    /// turned away, losing both the reason and the knowledge that the text was still alive.
    static func statusLine(
        state: DictationState,
        isDictationReady: Bool,
        isHandsFreeActive: Bool,
        hotkeyTitle: String,
        hasRecoveredText: Bool = false,
        hasRecoveredRecording: Bool = false
    ) -> String {
        switch state {
        case .idle:
            // The text is more important than the record: it has already been recognized, and before the finished result
            // the person has one menu item left.
            if hasRecoveredText {
                return "Text ready to copy or retry"
            }
            if hasRecoveredRecording {
                return "A recording is waiting to be transcribed"
            }
            return isDictationReady
                ? "Ready"
                : "Setup needed"
        case .preparing: return "Turning on the microphone…"
        case .listening:
            // In non-hold mode, the key is released and recording continues.
            // Not talking about it means leaving the person with the switch on
            // microphone and make sure that it is already turned off.
            return isHandsFreeActive
                ? "Listening — press \(hotkeyTitle) to finish"
                : "Listening"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Ready"
        }
    }
}
