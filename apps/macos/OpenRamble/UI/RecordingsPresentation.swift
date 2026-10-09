import DictationCore
import Foundation

/// Calendar sections belong to the library presentation, never to stored titles.
struct RecordingDayGroup: Identifiable {
    let day: Date
    let recordings: [MeetingRecordingMetadata]
    var id: Date { day }

    static func make(_ recordings: [MeetingRecordingMetadata], calendar: Calendar = .current) -> [Self] {
        Dictionary(grouping: recordings) { calendar.startOfDay(for: $0.startedAt) }
            .map { Self(day: $0.key, recordings: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    func needsSeconds(for recording: MeetingRecordingMetadata, calendar: Calendar = .current) -> Bool {
        recordings.contains {
            $0.id != recording.id && calendar.isDate($0.startedAt, equalTo: recording.startedAt, toGranularity: .minute)
        }
    }

    var title: String {
        if Calendar.current.isDateInToday(day) { return L10n.tr("Today") }
        if Calendar.current.isDateInYesterday(day) { return L10n.tr("Yesterday") }
        return day.formatted(.dateTime.day().month(.wide).year().locale(L10n.shared.language.locale))
    }
}

/// Consecutive paragraphs from one audio source. Paragraph identity and timing stay intact.
struct TranscriptSection: Identifiable {
    private(set) var utterances: [MeetingUtterance]
    var id: UUID { utterances[0].id }
    var channel: MeetingChannel { utterances[0].channel }

    static func make(_ utterances: [MeetingUtterance]) -> [Self] {
        var sections: [Self] = []
        for utterance in utterances.sorted(by: { $0.start < $1.start }) {
            if let last = sections.last, last.channel == utterance.channel {
                sections[sections.count - 1].utterances.append(utterance)
            } else {
                sections.append(Self(utterances: [utterance]))
            }
        }
        return sections
    }
}

/// Only an explicit scroll or return-to-latest changes whether new text follows.
struct TranscriptFollowState {
    private(set) var followsLatest = true

    mutating func userScrolled(distanceFromBottom: CGFloat) {
        followsLatest = distanceFromBottom <= 24
    }
    mutating func returnToLatest() { followsLatest = true }
}
