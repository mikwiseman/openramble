import DictationCore

/// The menu bar icon and what they say about it.
///
/// The icon is the only permanent presence of the application on the screen. Picture
/// without a description for a blind person does not exist at all: VoiceOver will read
/// name of the system symbol like “mic.slash” or remain silent.
enum MenuBarStatus {
    /// The brand mark, shown when nothing is happening.
    ///
    /// The menu bar is the only permanent presence this app has, so at rest it
    /// should say whose it is. It gives that up the moment there is something
    /// to report: a microphone that is listening, or work left unfinished, has
    /// to be visible at a glance, and a logo cannot say either.
    static let brandIconName = "BrandIconMenuBar"

    static func usesBrandIcon(
        state: DictationState,
        isDictationReady: Bool,
        hasRecoveredWork: Bool = false
    ) -> Bool {
        state == .idle && isDictationReady && !hasRecoveredWork
    }

    static func iconName(
        state: DictationState,
        isDictationReady: Bool,
        hasRecoveredWork: Bool = false
    ) -> String {
        switch state {
        case .listening: return "mic.fill"
        case .transcribing, .inserting: return "waveform"
        case .preparing, .idle:
            // The saved text or entry is visible only inside the menu - and the menu
            // open when they suspect something. Exclamation badge on
            //wave is the only way to say “there is unfinished work”
            // to a person who doesn’t look at the menu. Symbol name is fixed
            // existence test: a non-existent name gives an empty icon,
            // what's worse than not having a badge.
            if hasRecoveredWork, state == .idle {
                return "waveform.badge.exclamationmark"
            }
            return isDictationReady ? "mic" : "mic.slash"
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
        case .inserting: return "OpenRamble: ready to dictate"
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
