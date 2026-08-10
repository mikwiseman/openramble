import XCTest
@testable import DictationCore

/// Mode by recipient application.
final class PromptModeTests: XCTestCase {
    private func target(_ bundleIdentifier: String?, name: String? = nil) -> TargetApplication {
        TargetApplication(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: 42,
            localizedName: name
        )
    }

    // MARK: - Categories

    func testTerminalsAndEditorsAreVerbatim() {
        let policy = PromptModePolicy()
        for identifier in [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "com.microsoft.VSCode",
            "com.apple.dt.Xcode",
            "dev.zed.Zed",
        ] {
            XCTAssertEqual(policy.mode(for: target(identifier)), .verbatim, identifier)
        }
    }

    func testChatsMailAndNotesAreProse() {
        let policy = PromptModePolicy()
        for identifier in [
            "com.tinyspeck.slackmacgap",
            "com.apple.mail",
            "com.apple.Notes",
            "md.obsidian",
            "com.apple.Safari",
        ] {
            XCTAssertEqual(policy.mode(for: target(identifier)), .prose, identifier)
        }
    }

    /// The bundle id register should not decide: the system gives it as is.
    func testBundleIdentifierIsMatchedCaseInsensitively() {
        let policy = PromptModePolicy()
        XCTAssertEqual(policy.mode(for: target("COM.APPLE.TERMINAL")), .verbatim)
        XCTAssertEqual(policy.mode(for: target("com.apple.terminal")), .verbatim)
    }

    // MARK: - Default

    /// **Unfamiliar application - verbatim.**
    ///
    /// An error in this direction will leave an extra word. Error in another quietly
    /// will rewrite the command in the terminal, which we simply did not recognize.
    func testUnknownApplicationDefaultsToVerbatim() {
        let policy = PromptModePolicy()
        XCTAssertEqual(policy.mode(for: target("com.example.something")), .verbatim)
        XCTAssertEqual(policy.mode(for: target(nil)), .verbatim)
        XCTAssertEqual(policy.mode(for: nil), .verbatim)
    }

    func testUnknownCategoryDefaultIsVerbatim() {
        XCTAssertEqual(ApplicationCategory.unknown.defaultMode, .verbatim)
    }

    // MARK: - Precedent

    func testUserOverrideBeatsTheMap() {
        let policy = PromptModePolicy(overrides: ["com.apple.terminal": .prose])
        XCTAssertEqual(
            policy.mode(for: target("com.apple.Terminal")), .prose,
            "\u{0432}\u{044B}\u{0431}\u{043E}\u{0440} \u{0447}\u{0435}\u{043B}\u{043E}\u{0432}\u{0435}\u{043A}\u{0430} \u{0433}\u{043B}\u{0430}\u{0432}\u{043D}\u{0435}\u{0435} \u{043D}\u{0430}\u{0448}\u{0435}\u{0439} \u{043A}\u{0430}\u{0440}\u{0442}\u{044B}"
        )
    }

    func testUserOverrideCanForceVerbatimInAChat() {
        let policy = PromptModePolicy(overrides: ["com.tinyspeck.slackmacgap": .verbatim])
        XCTAssertEqual(policy.mode(for: target("com.tinyspeck.slackmacgap")), .verbatim)
    }

    func testOverrideForOneApplicationDoesNotLeakToOthers() {
        let policy = PromptModePolicy(overrides: ["com.apple.terminal": .prose])
        XCTAssertEqual(policy.mode(for: target("com.googlecode.iterm2")), .verbatim)
    }

    // MARK: - Name as a reserve attribute

    /// The name is the second attempt, not the first: the bundle id is stable, and the name
    /// localized and changed between versions.
    func testNameIsOnlyAFallback() {
        let policy = PromptModePolicy()
        XCTAssertEqual(
            policy.mode(for: target("com.unknown.thing", name: "Some Terminal")), .verbatim
        )
        // The familiar id decides for itself, no matter what is in the name.
        XCTAssertEqual(
            policy.mode(for: target("com.apple.Notes", name: "Terminal")), .prose,
            "bundle id \u{0437}\u{043D}\u{0430}\u{043A}\u{043E}\u{043C} — \u{0438}\u{043C}\u{044F} \u{043D}\u{0435} \u{0441}\u{043F}\u{0440}\u{0430}\u{0448}\u{0438}\u{0432}\u{0430}\u{0435}\u{043C}"
        )
    }

    /// “Code” is deliberately not a sign: too many things are called that way.
    func testGenericWordsInNamesDoNotDecide() {
        let policy = PromptModePolicy()
        XCTAssertEqual(PromptModePolicy.category(for: target("x.y", name: "Code Notes")), .unknown)
        XCTAssertEqual(policy.mode(for: target("x.y", name: "Code Notes")), .verbatim)
    }

    // MARK: - Map

    func testCategoryIsExposedForSettings() {
        XCTAssertEqual(PromptModePolicy.category(for: target("com.apple.Terminal")), .terminal)
        XCTAssertEqual(PromptModePolicy.category(for: target("com.apple.mail")), .mail)
        XCTAssertEqual(PromptModePolicy.category(for: target("com.example.nope")), .unknown)
    }

    /// The map contains only lowercase keys - otherwise the search using lowercased() will miss
    /// silently, and the application will simply receive the wrong mode.
    func testSeedKeysAreAllLowercased() {
        for key in PromptModePolicy.seed.keys {
            XCTAssertEqual(key, key.lowercased(), "\u{043A}\u{043B}\u{044E}\u{0447} \u{043A}\u{0430}\u{0440}\u{0442}\u{044B} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0431}\u{044B}\u{0442}\u{044C} \u{0432} \u{043D}\u{0438}\u{0436}\u{043D}\u{0435}\u{043C} \u{0440}\u{0435}\u{0433}\u{0438}\u{0441}\u{0442}\u{0440}\u{0435}: \(key)")
        }
    }

    func testEveryCategoryHasAMode() {
        for category in ApplicationCategory.allCases {
            XCTAssertTrue(PromptMode.allCases.contains(category.defaultMode))
        }
    }
}
