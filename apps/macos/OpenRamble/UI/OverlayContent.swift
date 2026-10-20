import DictationCore
import Foundation

/// What is written on the dictation panel.
///
/// The panel is the only feedback channel during dictation: from your window
/// no application. Therefore, its contents are collected as a separate type and
/// checked by the state table, not by looking at the screen.
///
/// A take has one shape from key-down to text: the same 244-point panel with a
/// mark, a waveform and a clock. Only the mark's color moves — gray while the
/// microphone starts, red while it records, blue while the words are worked
/// on. Most takes finish inside half a second of release, so a title appears
/// only when a state outlasts that: a panel that changed layout three times
/// in 200 ms said nothing anyone could read.
struct OverlayContent: Equatable {
    /// What a notice is. Notices are the only thing drawn with an icon.
    enum Tone: Equatable {
        case info
        case warning
        case failure

        /// The status color the panel paints this tone with. Failure joins
        /// `.attention` deliberately: every failure here is recoverable by the
        /// never-silently-discard rule, so it is "attention + work preserved",
        /// not a destructive red — red stays reserved for the live microphone.
        /// The warning/failure difference survives in copy and announcement
        /// urgency.
        var colorRole: StatusColorRole {
            switch self {
            case .info: return .processing
            case .warning, .failure: return .attention
            }
        }

        var iconName: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning, .failure: return "exclamationmark.triangle.fill"
            }
        }
    }

    /// The take's one mark, in the same place for the whole take.
    enum Mark: Equatable {
        /// Gray: the key is down, the microphone is not live yet.
        case starting
        /// Red: the microphone is capturing.
        case recording
        /// Blue: the microphone is closed and the words are being worked on.
        case working

        var colorRole: StatusColorRole? {
            switch self {
            case .starting: return nil
            case .recording: return .recording
            case .working: return .processing
            }
        }
    }

    /// Words on the panel, or `nil` while the take's shape says enough.
    var title: String?
    /// Notices only.
    var tone: Tone?
    /// Takes only.
    var mark: Mark?
    /// A shortcut to the entire panel for VoiceOver.
    ///
    /// The panel does not take focus on purpose - otherwise the insertion would break - that is
    /// by itself, a blind person does not get it in any way. The shortcut is needed for
    /// those who search for it with the VoiceOver cursor.
    var accessibilityLabel: String
    /// What VoiceOver hears on entering this state. `nil` - nothing.
    var voice: Voice?

    /// VoiceOver never speaks while the microphone is open: whatever it says
    /// then is played into that microphone and dictated. The moment it opens
    /// is a tone; words wait until it has closed.
    enum Voice: Equatable {
        case cue
        /// An urgent announcement interrupts what VoiceOver is currently reading.
        case speech(String, urgent: Bool)
    }

    /// One width per kind: every take state shares the recording layout, so
    /// the panel never re-centres mid-take; a notice needs room for a sentence.
    var panelWidth: Double { tone == nil ? 244 : 320 }

    /// How long a state lasts before it earns a title or a spoken word.
    static let titleDelay: Duration = .milliseconds(500)

    /// - Parameter hasLingered: the state has outlasted `titleDelay`.
    static func make(
        state: DictationState,
        notice: DictationNotice?,
        elapsed: TimeInterval,
        isWaitingForEngine: Bool = false,
        hasLingered: Bool = false
    ) -> OverlayContent {
        // The message is more important than the state: it is shown instead.
        if let notice {
            return OverlayContent(
                title: notice.message,
                tone: tone(for: notice.kind),
                accessibilityLabel: notice.message,
                // The message comes exactly when something goes wrong.
                // Waiting for the end of someone else's phrase means saying too much
                //too late for this to be useful.
                voice: .speech(notice.message, urgent: notice.kind != .info)
            )
        }

        switch state {
        case .idle:
            return OverlayContent(
                accessibilityLabel: L10n.tr("Not dictating"),
                // The panel is removed at this moment. Announcing “ready” into the void
                // no need: the person already heard that the dictation was over.
                voice: nil
            )

        case .preparing:
            return OverlayContent(
                title: hasLingered ? L10n.tr("Turning on the microphone…") : nil,
                mark: .starting,
                accessibilityLabel: L10n.tr("Turning on the microphone"),
                // Said while the microphone opens, so it would be dictated.
                voice: nil
            )

        case .listening:
            let seconds = spokenSeconds(elapsed)
            return OverlayContent(
                mark: .recording,
                accessibilityLabel: L10n.tr("Recording, %@.", String(describing: seconds)),
                // The main cue throughout the application: without it, a blind
                // person does not know that the microphone is on.
                voice: .cue
            )

        case .transcribing:
            // The words are safe either way, and the distinction is the
            // difference between a panel that is working and a panel that is
            // waiting. A model that has to be loaded costs seconds, and on a
            // short take there is no speech for that load to hide under, so
            // "Transcribing…" would spend the whole wait describing work that
            // has not started. Nothing is lost and nothing is at risk here —
            // say what is actually happening, and say it at once.
            if isWaitingForEngine {
                return OverlayContent(
                    title: L10n.tr("Waking the model…"),
                    mark: .working,
                    accessibilityLabel: L10n.tr("Recording stopped, waiting for the speech model to load")
                        + ". " + L10n.tr("Your words are waiting, not lost."),
                    voice: .speech(L10n.tr("Waiting for the speech model to load"), urgent: false)
                )
            }
            return OverlayContent(
                title: hasLingered ? L10n.tr("Transcribing…") : nil,
                mark: .working,
                accessibilityLabel: L10n.tr("Recording stopped, transcribing speech"),
                voice: hasLingered ? .speech(L10n.tr("Transcribing…"), urgent: false) : nil
            )

        case .inserting:
            return OverlayContent(
                accessibilityLabel: L10n.tr("Text inserted"),
                voice: nil
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
        return RecordingTime.spokenUnit(value, "second")
    }
}
