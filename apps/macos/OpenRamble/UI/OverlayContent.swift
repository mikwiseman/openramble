import DictationCore
import Foundation

/// What is written on the take block.
///
/// The block is the only feedback channel during dictation: the app has no
/// window of its own at that moment. Therefore its contents are collected as a
/// separate type and checked by the state table, not by looking at the screen.
///
/// A take has one shape from key-down to text: the same block with a glyph, a
/// meter and a clock, and no words. Its job is to show that dictation is
/// working without asking to be read. The glyph carries the state — a hollow
/// ring while the microphone starts, a red disc while it records, a red lock
/// while it records hands-free, a blue ring while the words are written down
/// — and color only confirms it. Most takes finish inside half a second of
/// release, so a title appears only when a state outlasts that, and it is
/// set quietly.
///
/// When the words cannot land the block grows to hold them, in full, with the
/// reason and the one action that works now. See `WaitingWords`.
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
        /// A red lock: capturing with the key let go, until it is pressed
        /// again — the locked-recording sign of voice messages.
        case handsFree
        /// Gray: the microphone has closed. Nine takes in ten end here, so no
        /// color announces work that is over before it could be read.
        case closed
        /// Blue: the words are being written down, and it is taking a while.
        case working

        var colorRole: StatusColorRole? { glyph.colorRole }

        /// The shape this state wears.
        var glyph: StateGlyph {
            switch self {
            case .starting, .closed: return .silent
            case .recording: return .listening
            case .handsFree: return .handsFree
            case .working: return .working
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
    /// Words that could not land. The block grows to hold them.
    var waiting: WaitingWords?
    /// How a waiting take ended, said once before the block leaves.
    var outcome: TakeOutcome?

    /// VoiceOver never speaks while the microphone is open: whatever it says
    /// then is played into that microphone and dictated. The moment it opens
    /// is a tone; words wait until it has closed.
    enum Voice: Equatable {
        case cue
        /// An urgent announcement interrupts what VoiceOver is currently reading.
        case speech(String, urgent: Bool)
    }

    /// One width per kind: every take state shares the recording layout,
    /// hands-free included, so the block never re-centres mid-take; a notice
    /// needs room for a sentence, and waiting words need room to be read in
    /// full.
    var panelWidth: Double {
        if waiting != nil { return 384 }
        if outcome != nil { return 320 }
        return tone == nil ? 244 : 320
    }

    /// The one glyph the block shows.
    var glyph: StateGlyph? {
        if let waiting { return waiting.glyph }
        if let outcome { return outcome.glyph }
        if let tone { return tone == .info ? .info : .attention }
        return mark?.glyph
    }

    /// Whether the block shows what the person said. While it does, it is
    /// kept out of screen captures and recordings.
    var showsDictatedWords: Bool { waiting != nil }

    /// How long a state lasts before it earns a title or a spoken word.
    static let titleDelay: Duration = .milliseconds(500)

    /// - Parameters:
    ///   - hasLingered: the state has outlasted `titleDelay`.
    ///   - handsFreeFinishKey: the key that ends a hands-free take, while one
    ///     runs; `nil` while the key is held.
    ///   - waiting: words that could not land.
    ///   - outcome: how a waiting take just ended.
    ///   - key: the dictation key, as drawn and as spoken.
    static func make(
        state: DictationState,
        notice: DictationNotice?,
        elapsed: TimeInterval,
        isWaitingForEngine: Bool = false,
        hasLingered: Bool = false,
        handsFreeFinishKey: String? = nil,
        waiting: WaitingWords? = nil,
        outcome: TakeOutcome? = nil,
        key: DictationHotkey = SettingsDefaults.hotkey
    ) -> OverlayContent {
        // How the waiting ended is the last word on it.
        if let outcome {
            return OverlayContent(
                accessibilityLabel: outcome.message,
                voice: .speech(outcome.message, urgent: false),
                outcome: outcome
            )
        }

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

        // Words wait only while nothing else is happening: a new take files
        // them in History before its microphone opens.
        if let waiting, state == .idle || state == .inserting {
            let label = waiting.accessibilityLabel(keyName: key.title, key: key.shortTitle)
            return OverlayContent(
                accessibilityLabel: label,
                // The person is looking at the app the words were meant for,
                // so this interrupts, like every other failed landing.
                voice: .speech(label, urgent: true),
                waiting: waiting
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
            if let handsFreeFinishKey {
                // The lock is the whole message. The way out is the key the
                // person just pressed twice, pressed once more; a key cap and
                // a word for it made the block wider and louder than the take
                // it describes. VoiceOver reads it on demand: said aloud it
                // would be said into the open microphone.
                return OverlayContent(
                    mark: .handsFree,
                    accessibilityLabel: L10n.tr(
                        "Recording hands-free, %@. Press %@ to finish.",
                        String(describing: seconds),
                        handsFreeFinishKey
                    ),
                    voice: .cue
                )
            }
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
                    title: L10n.tr("Getting ready…"),
                    mark: .working,
                    accessibilityLabel: L10n.tr("Recording stopped, waiting for the speech model to load")
                        + ". " + L10n.tr("Your words are waiting, not lost."),
                    voice: .speech(L10n.tr("Waiting for the speech model to load"), urgent: false)
                )
            }
            return OverlayContent(
                title: hasLingered ? L10n.tr("Writing it down…") : nil,
                mark: hasLingered ? .working : .closed,
                accessibilityLabel: L10n.tr("Recording stopped, transcribing speech"),
                voice: hasLingered ? .speech(L10n.tr("Writing it down…"), urgent: false) : nil
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
