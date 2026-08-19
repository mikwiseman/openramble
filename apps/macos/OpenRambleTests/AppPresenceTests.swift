import XCTest

/// The app can be moved, never hidden.
final class AppPresenceTests: XCTestCase {
    /// Every choice shows the app somewhere.
    ///
    /// This is the whole rule, and it is a rule rather than a default because
    /// an app with neither icon cannot be opened to give itself one back. The
    /// setting would be a door that locks behind the person who used it.
    func testEveryChoiceLeavesTheAppReachable() {
        for presence in AppPresence.allCases {
            XCTAssertTrue(
                presence.showsMenuBarIcon || presence.showsDockIcon,
                "\(presence) would make OpenRamble invisible"
            )
        }
    }

    /// The default is the menu bar: this is a dictation utility, not an app
    /// someone keeps open.
    func testTheDefaultIsTheMenuBar() {
        XCTAssertEqual(SettingsDefaults.presence, .menuBar)
        XCTAssertTrue(SettingsDefaults.presence.showsMenuBarIcon)
        XCTAssertFalse(SettingsDefaults.presence.showsDockIcon)
    }

    /// Each choice means what it says.
    func testEachChoiceShowsWhatItNames() {
        XCTAssertFalse(AppPresence.menuBar.showsDockIcon)
        XCTAssertFalse(AppPresence.dock.showsMenuBarIcon)
        XCTAssertTrue(AppPresence.both.showsMenuBarIcon)
        XCTAssertTrue(AppPresence.both.showsDockIcon)
    }
}
