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

    static let emptyLibrary = RecordingsPlaceholder(
        symbol: "waveform",
        title: "No recordings yet",
        detail: "Press the red button to record a meeting or a voice note. Everything stays on this Mac."
    )

    static let nothingSelected = RecordingsPlaceholder(
        symbol: "waveform",
        title: "Select a recording",
        detail: "Its audio and transcript appear here."
    )

    static let notTranscribed = RecordingsPlaceholder(
        symbol: "text.alignleft",
        title: "Not transcribed yet",
        detail: "Transcription for recordings is coming in a later version. The audio is complete and plays back."
    )

    static let audioMissing = RecordingsPlaceholder(
        symbol: "waveform.slash",
        title: "Recording no longer on disk",
        detail: "Its audio file was moved or deleted outside OpenRamble. The entry can be removed."
    )

    static let recovered = RecordingsPlaceholder(
        symbol: "waveform.badge.exclamationmark",
        title: "Recovered after an interruption",
        detail: "OpenRamble stopped before this recording could end normally. Everything recorded up to that moment was kept."
    )

    /// A one-line explanation of how a recording ended, when it did not end
    /// by the person's hand. `nil` for the ordinary case.
    static func endNote(for reason: MeetingEndReason?) -> String? {
        switch reason {
        case nil, .stoppedByUser: return nil
        case .diskFull: return "Stopped because this Mac ran out of space. Everything up to that moment was kept."
        case .writeFailed: return "Stopped because the recording could no longer be written. Everything up to that moment was kept."
        case .applicationQuit: return "Stopped when OpenRamble quit."
        case .crashRecovered: return "Recovered after an interruption. Everything recorded up to that moment was kept."
        }
    }

    /// The title a recording shows when the person has not given it one.
    static func defaultTitle(for startedAt: Date) -> String {
        startedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
