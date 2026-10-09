import DictationCore
import Foundation

/// Every empty, waiting and degraded state of the Recordings window, as data.
///
/// Held in one place so the strings can be read together and tested
/// together, the way `ModelStatus` does it: a placeholder decided inside a
/// view is a placeholder nobody proofreads.
struct RecordingsPlaceholder: Equatable {
    let symbol: String
    let title: String
    let detail: String

    static var emptyLibrary: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "waveform",
        title: L10n.tr("No recordings yet"),
        detail: L10n.tr("Press the red button to record a meeting or a voice note. Everything stays on this Mac.")
    ) }

    static var nothingSelected: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "waveform",
        title: L10n.tr("Select a recording"),
        detail: L10n.tr("Its audio and transcript appear here.")
    ) }

    static var listening: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "text.alignleft",
        title: L10n.tr("Listening"),
        detail: L10n.tr("Your transcript appears here as you speak.")
    ) }

    static var stillTranscribing: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "text.alignleft",
        title: L10n.tr("Still transcribing"),
        detail: L10n.tr("The rest of this recording is being transcribed. The audio is complete.")
    ) }

    static var noSpeech: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "text.alignleft",
        title: L10n.tr("Nothing to transcribe"),
        detail: L10n.tr("No speech was heard in this recording.")
    ) }

    static var transcriptionDidNotFinish: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "text.alignleft",
        title: L10n.tr("Transcription didn't finish"),
        detail: L10n.tr("The audio is complete; the transcript is not.")
    ) }

    static var waitingForModel: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "clock",
        title: L10n.tr("Waiting for the speech model"),
        detail: L10n.tr("Transcription starts once the model is downloaded and ready.")
    ) }

    static var notTranscribed: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "text.alignleft",
        title: L10n.tr("Not transcribed"),
        detail: L10n.tr("This recording was interrupted before it could be transcribed.")
    ) }

    /// What to show in place of an empty transcript, given how far it got.
    static func transcript(for state: MeetingTranscriptionState) -> RecordingsPlaceholder {
        switch state {
        case .none: return .notTranscribed
        case .live: return .stillTranscribing
        case .complete: return .noSpeech
        case .partial, .failed: return .transcriptionDidNotFinish
        case .waitingForModel: return .waitingForModel
        }
    }

    static var audioMissing: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "waveform.slash",
        title: L10n.tr("Recording no longer on disk"),
        detail: L10n.tr("Its audio file was moved or deleted outside OpenRamble. The entry can be removed.")
    ) }

    static var recovered: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "waveform.badge.exclamationmark",
        title: L10n.tr("Recovered after an interruption"),
        detail: L10n.tr("OpenRamble stopped before this recording could end normally. Everything recorded up to that moment was kept.")
    ) }

    /// A one-line explanation of how a recording ended, when it did not end
    /// by the person's hand. `nil` for the ordinary case.
    static func endNote(for reason: MeetingEndReason?) -> String? {
        switch reason {
        case nil, .stoppedByUser: return nil
        case .diskFull: return L10n.tr("Stopped because this Mac ran out of space. Everything up to that moment was kept.")
        case .writeFailed: return L10n.tr("Stopped because the recording could no longer be written. Everything up to that moment was kept.")
        case .applicationQuit: return L10n.tr("Stopped when OpenRamble quit.")
        case .crashRecovered: return L10n.tr("Recovered after an interruption. Everything recorded up to that moment was kept.")
        }
    }

    /// The line a recording carries forever when a requested side never arrived.
    static func degradedNote(for recording: MeetingRecordingMetadata) -> String? {
        let microphoneMissing = recording.microphoneEverDeliveredAudio == false
        let othersMissing = recording.systemAudio.wasRequested && !recording.systemAudio.everDeliveredAudio
        switch (microphoneMissing, othersMissing) {
        case (true, true):
            return L10n.tr("Neither your microphone nor the other side of this call was captured.")
        case (true, false):
            return recording.systemAudio.wasRequested
                ? L10n.tr("The other side of this call was recorded. Your microphone was not captured.")
                : L10n.tr("Your microphone was not captured.")
        case (false, true):
            return L10n.tr("Only your microphone was recorded. The other side of this call was not captured.")
        case (false, false):
            return nil
        }
    }

    /// The title a recording shows when the person has not given it one.
    static func defaultTitle(for startedAt: Date) -> String {
        startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.shared.language.locale))
    }
}
