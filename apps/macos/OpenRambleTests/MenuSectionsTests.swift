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
        recoveryFaulted: Bool = false,
        recents: Bool = false,
        recording: AppState.MeetingState = .idle
    ) -> [[MenuRow]] {
        MenuSections.sections(
            state: state,
            isDictationReady: ready,
            hasRecoveredText: recoveredText,
            recoveryStorageFaulted: recoveryFaulted,
            hasRecents: recents,
            recordingState: recording
        )
    }

    /// A running recording takes the place of the idle dictation hint. Active
    /// dictation still has its own controls — the two are orthogonal.
    func testARecordingAddsItsOwnSectionWhateverDictationIsDoing() {
        XCTAssertEqual(
            sections(recording: .recording),
            [[.recordingLine, .pauseRecording, .stopRecording], [.openRecordings, .settings, .quit]]
        )
        XCTAssertFalse(
            sections(recording: .recording).flatMap(\.self).contains(.startRecording),
            "stop replaces start; both at once would toggle twice"
        )
        XCTAssertEqual(
            sections(state: .listening, recording: .recording),
            [
                [.statusLine],
                [.recordingLine, .pauseRecording, .stopRecording],
                [.stopAndInsert, .cancelDictation],
                [.openRecordings, .settings, .quit],
            ]
        )
    }

    /// Two actions, not a hidden mode: "Start Recording" always records
    /// audio, and "Record Screen…" is always one click away. A segmented
    /// Audio|Screen choice in the Recordings window used to decide silently
    /// what the menu's Start Recording did.
    func testScreenRecordingIsItsOwnAction() {
        let idle = sections().flatMap(\.self)
        XCTAssertTrue(idle.contains(.startRecording))
        XCTAssertTrue(idle.contains(.startScreenRecording))
        XCTAssertFalse(sections(recording: .recording).flatMap(\.self).contains(.startScreenRecording))
        XCTAssertFalse(sections(state: .listening).flatMap(\.self).contains(.startScreenRecording))
    }

    func testARecordingTakesFocusAndCanBePausedFromTheMenu() {
        let menu = sections(recording: .recording)
        XCTAssertEqual(menu.first?.first, .recordingLine)
        XCTAssertEqual(menu.first?.count, 3, "recording status, pause or resume, and stop")
    }

    func testAPausedRecordingCanResumeOrStopWithoutOpeningAWindow() {
        XCTAssertEqual(sections(recording: .paused), [
            [.recordingLine, .resumeRecording, .stopRecording], [.openRecordings, .settings, .quit],
        ])
    }

    func testStartingAndSavingNeverOfferANonfunctionalStartButton() {
        for recording in [AppState.MeetingState.starting, .stopping] {
            XCTAssertEqual(sections(recording: recording), [[.recordingLine], [.openRecordings, .settings, .quit]])
        }
    }

    func testUninsertedDictationStillNeedsAttentionWhileRecording() {
        XCTAssertEqual(sections(recoveredText: true, recording: .paused).first, [.statusLine])
        XCTAssertTrue(sections(recoveredText: true, recording: .paused).flatMap(\.self).contains(.insertLastDictation))
    }

    /// The common case: a ready, quiet app shows start-recording as its own
    /// section, so the shortcut has a row the way Copy Last Dictation does.
    func testScenario001() {
        XCTAssertEqual(
            sections(),
            [[.statusLine], [.startRecording, .startScreenRecording], [.openRecordings, .settings, .quit]]
        )
    }

    /// Everything on at once — still at most five top-level row units.
    func testScenario002() {
        XCTAssertEqual(
            sections(recoveredText: true, recents: true),
            [
                [.statusLine],
                [.insertLastDictation],
                [.recentDictations, .copyLast],
                [.startRecording, .startScreenRecording],
                [.openRecordings, .settings, .quit],
            ]
        )
    }

    /// While a session runs, the menu is about the session — history and
    /// recovery wait; nothing else can be acted on anyway.
    func testScenario003() {
        for state in [DictationState.preparing, .listening] {
            XCTAssertEqual(
                sections(state: state, recoveredText: true, recents: true),
                [
                    [.statusLine],
                    [.stopAndInsert, .cancelDictation],
                    [.openRecordings, .settings, .quit],
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
                [[.statusLine], [.openRecordings, .settings, .quit]],
                "\(state) must show only the status"
            )
        }
    }

    /// Setup rows appear only while something is missing.
    func testScenario005() {
        XCTAssertEqual(
            sections(ready: false),
            [[.statusLine], [.setupHints, .finishSetup], [.startRecording, .startScreenRecording], [.openRecordings, .settings, .quit]]
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
                [.recentDictations, .copyLast],
                [.startRecording, .startScreenRecording],
                [.openRecordings, .settings, .quit],
            ]
        )
    }

    /// Settings and Quit close every menu, in every state.
    func testScenario008() {
        let variants: [[[MenuRow]]] = [
            sections(),
            sections(state: .listening),
            sections(state: .transcribing),
            sections(ready: false, recoveredText: true, recents: true),
        ]
        for variant in variants {
            XCTAssertEqual(variant.last, [.openRecordings, .settings, .quit])
        }
    }

    /// The removed rows stay removed: no state resurrects a saved-recording
    /// or delete item.
    func testScenario009() {
        let everything: Set<MenuRow> = Set(
            sections(ready: false, recoveredText: true, recents: true)
                .flatMap(\.self)
            + sections(state: .listening, recoveredText: true).flatMap(\.self)
            + sections(state: .transcribing, recoveredText: true).flatMap(\.self)
        )
        let allowed: Set<MenuRow> = [
            .statusLine, .stopAndInsert, .cancelDictation, .setupHints, .finishSetup,
            .insertLastDictation, .revealRecoveredRecordings,
            .recentDictations, .copyLast, .startRecording, .startScreenRecording, .openRecordings, .settings, .quit,
        ]
        XCTAssertTrue(everything.isSubset(of: allowed))
    }

    /// Retained audio no longer occupies the daily menu: the failure notice
    /// announces it when it happens and Settings keeps it findable. The one
    /// state that must stay in the menu is a recovery-storage fault — hiding
    /// voice data the app can no longer clean up would break the privacy
    /// promise.
    func testRecoveredAudioStaysOutOfTheMenuUnlessRecoveryFaulted() {
        XCTAssertEqual(
            sections(),
            [[.statusLine], [.startRecording, .startScreenRecording], [.openRecordings, .settings, .quit]],
            "ordinary retained recordings are a Settings affair, not menu debris"
        )
        XCTAssertEqual(
            sections(recoveryFaulted: true),
            [[.statusLine], [.revealRecoveredRecordings], [.startRecording, .startScreenRecording], [.openRecordings, .settings, .quit]]
        )
        XCTAssertFalse(
            sections(state: .listening, recoveryFaulted: true)
                .flatMap(\.self)
                .contains(.revealRecoveredRecordings)
        )
    }
}
