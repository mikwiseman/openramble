import DictationCore
import XCTest

/// One library of everything said: dictations and recordings in one list by
/// day, with one search over both.
final class LibraryIndexTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    private func dictation(_ text: String, _ date: Date) -> HistoryEntry {
        HistoryEntry(date: date, text: text, audioFileName: nil)
    }

    private func recording(_ title: String?, _ date: Date) -> MeetingRecordingMetadata {
        MeetingRecordingMetadata(
            startedAt: date,
            title: title,
            systemAudio: SystemAudioSummary(wasRequested: false)
        )
    }

    private func days(
        scope: LibraryScope = .all,
        query: String = ""
    ) -> [LibraryDay] {
        LibraryIndex.days(
            dictations: [
                dictation("Send it to Ana by noon.", date(7, 9, 38)),
                dictation("Ship the menu bar fix before Friday.", date(6, 16, 12)),
                dictation("Напомни позвонить в банк в четыре.", date(7, 9, 12)),
            ],
            recordings: [
                recording("Weekly sync", date(7, 8, 2)),
                recording(nil, date(6, 17, 46)),
            ],
            scope: scope,
            query: query,
            calendar: calendar
        )
    }

    /// Newest day first, newest item first, both kinds in one run.
    func testDictationsAndRecordingsShareOneListByDay() {
        let all = days()
        XCTAssertEqual(all.map(\.day), [date(7, 0), date(6, 0)])
        XCTAssertEqual(all[0].items.map(\.date), [date(7, 9, 38), date(7, 9, 12), date(7, 8, 2)])
        XCTAssertEqual(all[1].items.map(\.date), [date(6, 17, 46), date(6, 16, 12)])
        guard case .recording = all[0].items[2], case .dictation = all[0].items[0] else {
            return XCTFail("both kinds in one day")
        }
    }

    func testAScopeShowsOneKind() {
        XCTAssertEqual(days(scope: .dictations).flatMap(\.items).count, 3)
        XCTAssertEqual(days(scope: .recordings).flatMap(\.items).count, 2)
        for item in days(scope: .recordings).flatMap(\.items) {
            guard case .recording = item else { return XCTFail("only recordings") }
        }
    }

    /// One search: a dictation is found by its words, a recording by its
    /// name. Case does not matter, in either alphabet.
    func testSearchFindsWordsAndNames() {
        XCTAssertEqual(days(query: "ana").flatMap(\.items).map(\.date), [date(7, 9, 38)])
        XCTAssertEqual(days(query: "WEEKLY").flatMap(\.items).map(\.date), [date(7, 8, 2)])
        XCTAssertEqual(days(query: "банк").flatMap(\.items).map(\.date), [date(7, 9, 12)])
        XCTAssertEqual(days(query: "БАНК").flatMap(\.items).count, 1)
        XCTAssertEqual(days(query: "nothing like this"), [])
        XCTAssertEqual(days(query: "   ").flatMap(\.items).count, 5, "a blank query finds everything")
    }

    /// A day with nothing left after the search is not listed at all.
    func testEmptyDaysAreNotListed() {
        XCTAssertEqual(days(query: "friday").map(\.day), [date(6, 0)])
    }

    /// Seconds appear only where two recordings would otherwise read alike.
    func testSecondsOnlyTellApartRecordingsOfOneMinute() {
        let first = recording(nil, date(7, 10, 0, 5))
        let second = recording(nil, date(7, 10, 0, 40))
        let alone = recording(nil, date(7, 11, 0, 0))
        let day = LibraryIndex.days(
            dictations: [dictation("Same minute, but not a recording.", date(7, 11, 0, 30))],
            recordings: [first, second, alone],
            calendar: calendar
        )[0]
        XCTAssertTrue(day.needsSeconds(for: first, calendar: calendar))
        XCTAssertTrue(day.needsSeconds(for: second, calendar: calendar))
        XCTAssertFalse(day.needsSeconds(for: alone, calendar: calendar))
    }

    /// The lasting fix is offered only where there is one to make: a
    /// terminal's own menu. A password field has none.
    func testTheLastingFixIsOnlyForTerminals() {
        let words = "Ping test"
        XCTAssertEqual(
            WaitingWords(words: words, cause: .typingProtected(by: "Terminal")).lastingFix,
            "To stop this, turn off Secure Keyboard Entry in Terminal's menu."
        )
        XCTAssertNotNil(WaitingWords(words: words, cause: .typingProtected(by: "iTerm2")).lastingFix)
        XCTAssertNil(WaitingWords(words: words, cause: .typingProtected(by: "1Password")).lastingFix)
        XCTAssertNil(WaitingWords(words: words, cause: .typingProtected(by: nil)).lastingFix)
        XCTAssertNil(WaitingWords(words: words, cause: .noTextField).lastingFix)
    }
}
