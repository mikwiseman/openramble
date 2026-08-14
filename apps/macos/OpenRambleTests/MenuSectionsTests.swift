import DictationCore
import XCTest

/// The menu's visibility matrix, pinned as data.
///
/// The menu is the whole interface at rest, and every extra row is a tax on a
/// person mid-thought. These tests document two removals as design decisions:
/// - Background audio transcription remains gone. Failed-transcription and
///   crash recordings expose one Finder destination with a count, so retention
///   is discoverable and deletion stays explicit.
/// - "Copy/Delete Saved Text" are gone. Failed-insert words join Recent
///   Dictations at failure time (copyable there), and the one recovery row is
///   "Insert Last Dictation". Do not re-add delete items.
final class MenuSectionsTests: XCTestCase {
    private func sections(
        state: DictationState = .idle,
        ready: Bool = true,
        recoveredText: Bool = false,
        recoveredRecordings: Bool = false,
        recents: Bool = false,
        copyAsSpoken: Bool = false
    ) -> [[MenuRow]] {
        MenuSections.sections(
            state: state,
            isDictationReady: ready,
            hasRecoveredText: recoveredText,
            hasRecoveredRecordings: recoveredRecordings,
            hasRecents: recents,
            canCopyAsSpoken: copyAsSpoken
        )
    }

    /// The common case: a ready, quiet app shows three rows in two sections.
    func testScenario001() {
        XCTAssertEqual(
            sections(),
            [[.statusLine], [.settings, .quit]]
        )
    }

    /// Everything on at once — still at most five top-level row units.
    func testScenario002() {
        XCTAssertEqual(
            sections(recoveredText: true, recents: true, copyAsSpoken: true),
            [
                [.statusLine],
                [.insertLastDictation],
                [.recentDictations, .copyLastAsSpoken],
                [.settings, .quit],
            ]
        )
    }

    /// While a session runs, the menu is about the session — history and
    /// recovery wait; nothing else can be acted on anyway.
    func testScenario003() {
        for state in [DictationState.preparing, .listening] {
            XCTAssertEqual(
                sections(state: state, recoveredText: true, recents: true, copyAsSpoken: true),
                [
                    [.statusLine],
                    [.stopAndInsert, .cancelDictation],
                    [.settings, .quit],
                ],
                "\(state) must show the session menu"
            )
        }
    }

    /// Transcribing lasts seconds and a menu opens slower than that: no
    /// cancel row. Escape still cancels.
    func testScenario004() {
        for state in [DictationState.transcribing, .inserting] {
            XCTAssertEqual(
                sections(state: state, recoveredText: true, recents: true),
                [[.statusLine], [.settings, .quit]],
                "\(state) must show only the status"
            )
        }
    }

    /// Setup rows appear only while something is missing.
    func testScenario005() {
        XCTAssertEqual(
            sections(ready: false),
            [[.statusLine], [.setupHints, .finishSetup], [.settings, .quit]]
        )
    }

    /// A person mid-setup keeps access to recovery and history.
    func testScenario006() {
        XCTAssertEqual(
            sections(ready: false, recoveredText: true, recents: true),
            [
                [.statusLine],
                [.setupHints, .finishSetup],
                [.insertLastDictation],
                [.recentDictations],
                [.settings, .quit],
            ]
        )
    }

    /// "Copy Last as Spoken" appears only when it would not duplicate the
    /// inserted text — the policy travels through canCopyAsSpoken.
    func testScenario007() {
        XCTAssertFalse(sections(recents: true).flatMap(\.self).contains(.copyLastAsSpoken))
        XCTAssertTrue(
            sections(recents: true, copyAsSpoken: true).flatMap(\.self).contains(.copyLastAsSpoken)
        )
    }

    /// Settings and Quit close every menu, in every state.
    func testScenario008() {
        let variants: [[[MenuRow]]] = [
            sections(),
            sections(state: .listening),
            sections(state: .transcribing),
            sections(ready: false, recoveredText: true, recents: true, copyAsSpoken: true),
        ]
        for variant in variants {
            XCTAssertEqual(variant.last, [.settings, .quit])
        }
    }

    /// The removed rows stay removed: no state resurrects a saved-recording
    /// or delete item.
    func testScenario009() {
        let everything: Set<MenuRow> = Set(
            sections(ready: false, recoveredText: true, recents: true, copyAsSpoken: true)
                .flatMap(\.self)
            + sections(state: .listening, recoveredText: true).flatMap(\.self)
            + sections(state: .transcribing, recoveredText: true).flatMap(\.self)
        )
        let allowed: Set<MenuRow> = [
            .statusLine, .stopAndInsert, .cancelDictation, .setupHints, .finishSetup,
            .insertLastDictation, .revealRecoveredRecordings,
            .recentDictations, .copyLastAsSpoken, .settings, .quit,
        ]
        XCTAssertTrue(everything.isSubset(of: allowed))
    }

    func testRecoveredAudioIsDiscoverableOnlyAtRest() {
        XCTAssertEqual(
            sections(recoveredRecordings: true),
            [[.statusLine], [.revealRecoveredRecordings], [.settings, .quit]]
        )
        XCTAssertFalse(
            sections(state: .listening, recoveredRecordings: true)
                .flatMap(\.self)
                .contains(.revealRecoveredRecordings)
        )
    }
}
