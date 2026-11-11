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
        title: L10n.tr("Nothing said yet"),
        detail: L10n.tr("Hold your dictation key to dictate, press the red button to record, or drop an audio file here. Everything stays on this Mac.")
    ) }

    static var nothingSelected: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "waveform",
        title: L10n.tr("Nothing selected"),
        detail: L10n.tr("Choose a dictation or a recording to read it here.")
    ) }

    /// The search, or the scope, leaves nothing to show.
    static var nothingFound: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "magnifyingglass",
        title: L10n.tr("Nothing found"),
        detail: L10n.tr("No dictation or recording matches.")
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

    /// What kind of thing a recording is, in two words.
    static func kind(of recording: MeetingRecordingMetadata) -> String {
        if recording.captureKind == .screen { return L10n.tr("Screen recording") }
        if recording.isImported { return L10n.tr("Imported file") }
        return recording.isMeeting ? L10n.tr("Meeting") : L10n.tr("Voice note")
    }

    static var importTranscribing: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "text.alignleft",
        title: L10n.tr("Transcribing"),
        detail: L10n.tr("The words appear here as they are read.")
    ) }

    static var importWaiting: RecordingsPlaceholder { RecordingsPlaceholder(
        symbol: "clock",
        title: L10n.tr("Waiting its turn"),
        detail: L10n.tr("Another file is being transcribed first. You can already play this one.")
    ) }

    /// What stands in for the words of an imported file that has none yet,
    /// or `nil` when the importer is not working on it.
    static func importing(_ id: UUID, activity: RecordingImporter.Activity) -> RecordingsPlaceholder? {
        if activity.transcribing == id { return .importTranscribing }
        guard activity.waiting.contains(id) else { return nil }
        return activity.needsModel && activity.transcribing == nil ? .waitingForModel : .importWaiting
    }

    /// What an imported recording says while its words are still coming, or
    /// `nil` once they are all there.
    static func importLine(
        for id: UUID,
        activity: RecordingImporter.Activity,
        isDictating: Bool
    ) -> String? {
        if activity.transcribing == id {
            if isDictating { return L10n.tr("Transcription paused while you dictate.") }
            return L10n.tr("Transcribing — %@ percent.", String(describing: Int((activity.fraction * 100).rounded(.down))))
        }
        guard activity.waiting.contains(id) else { return nil }
        // Only the first in line waits for a model; the rest wait for it.
        if activity.needsModel, activity.transcribing == nil {
            return L10n.tr("Waiting for the speech model.")
        }
        return L10n.tr("Waiting its turn.")
    }

    /// The title a recording shows when the person has not given it one.
    static func defaultTitle(for startedAt: Date) -> String {
        startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.shared.language.locale))
    }
}
