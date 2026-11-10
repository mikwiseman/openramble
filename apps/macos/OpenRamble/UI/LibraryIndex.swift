import DictationCore
import Foundation

/// What the Library shows: everything said, in one list.
///
/// Dictations and recordings were two windows with two lists, and a person
/// looking for something they said had to know which kind it was first. Here
/// they are one list by day, newest first, with one search over both.
enum LibraryScope: String, CaseIterable, Identifiable {
    case all
    case dictations
    case recordings

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return L10n.tr("All")
        case .dictations: return L10n.tr("Dictations")
        case .recordings: return L10n.tr("Recordings")
        }
    }
}

/// One thing that was said: a dictation, or a recording.
enum LibraryItem: Identifiable, Equatable {
    case dictation(HistoryEntry)
    case recording(MeetingRecordingMetadata)

    var id: UUID {
        switch self {
        case let .dictation(entry): return entry.id
        case let .recording(recording): return recording.id
        }
    }

    var date: Date {
        switch self {
        case let .dictation(entry): return entry.date
        case let .recording(recording): return recording.startedAt
        }
    }

    /// Whether the search finds it: a dictation by its words, a recording by
    /// its name. Case and diacritics do not matter; an empty query finds
    /// everything.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack: String
        switch self {
        case let .dictation(entry): haystack = entry.text
        case let .recording(recording): haystack = recording.title ?? ""
        }
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// One day of the Library, newest item first.
struct LibraryDay: Identifiable, Equatable {
    let day: Date
    let items: [LibraryItem]
    var id: Date { day }

    var title: String {
        if Calendar.current.isDateInToday(day) { return L10n.tr("Today") }
        if Calendar.current.isDateInYesterday(day) { return L10n.tr("Yesterday") }
        return day.formatted(.dateTime.day().month(.wide).year().locale(L10n.shared.language.locale))
    }

    /// Two recordings started in the same minute need seconds to be told
    /// apart; nothing else does.
    func needsSeconds(for recording: MeetingRecordingMetadata, calendar: Calendar = .current) -> Bool {
        items.contains { item in
            guard case let .recording(other) = item, other.id != recording.id else { return false }
            return calendar.isDate(other.startedAt, equalTo: recording.startedAt, toGranularity: .minute)
        }
    }
}

enum LibraryIndex {
    static func days(
        dictations: [HistoryEntry],
        recordings: [MeetingRecordingMetadata],
        scope: LibraryScope = .all,
        query: String = "",
        calendar: Calendar = .current
    ) -> [LibraryDay] {
        var items: [LibraryItem] = []
        if scope != .recordings { items += dictations.map(LibraryItem.dictation) }
        if scope != .dictations { items += recordings.map(LibraryItem.recording) }
        return Dictionary(grouping: items.filter { $0.matches(query) }) { calendar.startOfDay(for: $0.date) }
            .map { LibraryDay(day: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}

extension WaitingWords {
    /// How to stop the block from coming back, for the one cause that has a
    /// lasting fix the person can make: a terminal's Secure Keyboard Entry.
    /// Said only in the Library, never on the take block, where the answer
    /// that works now is all there is room for.
    var lastingFix: String? {
        guard case let .typingProtected(holder?) = cause,
              Self.terminals.contains(holder)
        else { return nil }
        return L10n.tr("To stop this, turn off Secure Keyboard Entry in %@'s menu.", holder)
    }

    /// The apps whose menu has Secure Keyboard Entry, by the name macOS shows.
    private static let terminals: Set<String> = ["Terminal", "Терминал", "iTerm2", "iTerm"]
}
