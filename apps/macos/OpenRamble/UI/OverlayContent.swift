import DictationCore
import Foundation

/// What is written on the dictation panel.
///
/// The panel is the only feedback channel during dictation: from your window
/// no application. Therefore, its contents are collected as a separate type and
/// checked by the state table, not by looking at the screen.
struct OverlayContent: Equatable {
    enum Tone: Equatable {
        case idle
        case recording
        case working
        case info
        case warning
        case failure
    }

    var title: String
    var subtitle: String?
    var tone: Tone
    /// A shortcut to the entire panel for VoiceOver.
    ///
    /// The panel does not take focus on purpose - otherwise the insertion would break - that is
    /// by itself, a blind person does not get it in any way. The shortcut is needed for
    /// those who search for it with the VoiceOver cursor.
    var accessibilityLabel: String
    /// What to say out loud when entering this state. `nil` - nothing to say.
    var announcement: String?
    /// An urgent announcement interrupts what VoiceOver is currently reading.
    var isAnnouncementUrgent: Bool

    static func make(
        state: DictationState,
        notice: DictationNotice?,
        elapsed: TimeInterval
    ) -> OverlayContent {
        // The message is more important than the state: it is shown instead.
        if let notice {
            return OverlayContent(
                title: notice.message,
                subtitle: nil,
                tone: tone(for: notice.kind),
                accessibilityLabel: notice.message,
                announcement: notice.message,
                // The message comes exactly when something goes wrong.
                // Waiting for the end of someone else's phrase means saying too much
                //too late for this to be useful.
                isAnnouncementUrgent: notice.kind != .info
            )
        }

        switch state {
        case .idle:
            return OverlayContent(
                title: "Done",
                subtitle: nil,
                tone: .idle,
                accessibilityLabel: "Not dictating",
                // The panel is removed at this moment. Announcing “ready” into the void
                // no need: the person already heard that the dictation was over.
                announcement: nil,
                isAnnouncementUrgent: false
            )

        case .preparing:
            return OverlayContent(
                title: "Turning on the microphone…",
                subtitle: nil,
                tone: .working,
                accessibilityLabel: "Turning on the microphone",
                announcement: "Turning on the microphone",
                isAnnouncementUrgent: false
            )

        case .listening:
            let seconds = spokenSeconds(elapsed)
            return OverlayContent(
                title: "Listening",
                subtitle: nil,
                tone: .recording,
                accessibilityLabel: "Recording, \(seconds).",
                // The main announcement throughout the application: without it, you are blind
                // the person does not know that the microphone is on.
                announcement: "Recording.",
                isAnnouncementUrgent: true
            )

        case .transcribing:
            return OverlayContent(
                title: "Transcribing…",
                // The number is the length of the finished recording, not progress.
                // Showing it next to a spinner looks like a processing timer and is misleading.
                subtitle: nil,
                tone: .working,
                accessibilityLabel: "Recording stopped, transcribing speech",
                announcement: "Recording stopped, transcribing speech",
                isAnnouncementUrgent: false
            )

        case .inserting:
            return OverlayContent(
                title: "Done",
                subtitle: nil,
                tone: .idle,
                accessibilityLabel: "Text inserted",
                announcement: nil,
                isAnnouncementUrgent: false
            )
        }
    }

    private static func tone(for kind: DictationNotice.Kind) -> Tone {
        switch kind {
        case .info: return .info
        case .warning: return .warning
        case .failure: return .failure
        }
    }

    /// The same number in words.
    ///
    /// "5 s" VoiceOver reads as "5 es". For the only sign that
    /// The recording is really going on, but that’s not enough.
    static func spokenSeconds(_ elapsed: TimeInterval) -> String {
        let value = Int(max(0, elapsed).rounded())
        return "\(value) \(secondsWord(value))"
    }

    /// Form of the word "second" for a number.
    private static func secondsWord(_ value: Int) -> String {
        value == 1 ? "second" : "seconds"
    }
}
