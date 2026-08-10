import AppKit
import LocalASR
import DictationCore
import XCTest

/// The menu bar icon is the only persistent presence of the application.
///
/// A picture without a description does not exist at all for a blind person: VoiceOver
/// will read the name of the system symbol or remain silent.
final class MenuBarStatusTests: XCTestCase {
    func testScenario001() {
        XCTAssertEqual(MenuBarStatus.iconName(state: .listening, isDictationReady: true), "mic.fill")
        XCTAssertEqual(MenuBarStatus.iconName(state: .transcribing, isDictationReady: true), "waveform")
        XCTAssertEqual(MenuBarStatus.iconName(state: .inserting, isDictationReady: true), "waveform")
        XCTAssertEqual(MenuBarStatus.iconName(state: .idle, isDictationReady: true), "mic")
    }

    /// An unconfigured application must have a different icon.
    ///
    /// Otherwise, the person will hold the key and not understand why nothing
    /// happens.
    func testScenario002() {
        XCTAssertEqual(MenuBarStatus.iconName(state: .idle, isDictationReady: false), "mic.slash")
    }

    func testScenario003() {
        let states: [DictationState] = [.idle, .preparing, .listening, .transcribing, .inserting]

        for state in states {
            for ready in [true, false] {
                let label = MenuBarStatus.accessibilityLabel(state: state, isDictationReady: ready)
                XCTAssertFalse(label.isEmpty)
                // There are a lot of icons in the menu bar: “recording in progress” without an owner
                // says nothing.
                XCTAssertTrue(label.hasPrefix("OpenRamble"), "'\(label)' does not name the application")
            }
        }
    }

    func testScenario004() {
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(state: .listening, isDictationReady: true),
            "OpenRamble: recording"
        )
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(state: .idle, isDictationReady: false),
            "OpenRamble: setup needed"
        )
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(state: .idle, isDictationReady: true),
            "OpenRamble: ready to dictate"
        )
    }

    func testScenario005() {
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .idle, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Right Command"),
            "Ready"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .idle, isDictationReady: false, isHandsFreeActive: false, hotkeyTitle: "Right Command"),
            "Setup needed"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .listening, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Fn (🌐)"),
            "Listening"
        )
    }
}

/// Menu in the menu bar: what it offers about the model.
///
/// Previously, the menu knew one boolean about the model and offered “Download” even in the middle
/// loading: pressing went nowhere, and the status bar said “Need
/// setup”, without mentioning the ongoing download. Now the menu takes the same
/// six states, same as both screens.
@MainActor
final class MenuModelOfferTests: XCTestCase {
    private func status(for state: ModelState) -> ModelStatus {
        ModelStatus.make(state: state, isPreparingEngine: false, place: .settings)
    }

    func testScenario006() {
        let model = status(for: .downloading(receivedBytes: 200_000_000, totalBytes: 483_105_645))

        XCTAssertFalse(
            model.actions.contains(.install),
            "Do not offer another installation while a download is already in progress."
        )
        XCTAssertNotNil(model.progressLabel, "The person should see that loading is in progress")
    }

    func testScenario007() {
        let model = status(for: .verifying(checked: 8, total: 21))

        XCTAssertFalse(model.actions.contains(.install))
        XCTAssertNotNil(model.progressLabel)
    }

    func testScenario008() {
        let model = status(for: .failed(.download("network unavailable")))

        XCTAssertTrue(model.actions.contains(.retry), "There must be a way out of the error")
    }

    func testScenario009() {
        let model = status(for: .notInstalled)

        XCTAssertTrue(model.actions.contains(.install))
    }

    /// The menu must name the actual remainder, and not the complete installation.
    ///
    /// After updating from a build without a prompt, you need to download ~103 MB, and the menu
    /// took the default volume and promised 586 - a five-fold error. According to this
    /// The numbers decide whether to use an expensive or slow network.
    func testScenario010() {
        let model = ModelStatus.make(
            state: .notInstalled,
            isPreparingEngine: false,
            place: .settings,
            downloadMegabytes: 103
        )

        let title = model.title(for: .install)
        XCTAssertTrue(title.contains("103 MB"), "said: \(title)")
        XCTAssertFalse(title.contains("586"), "full volume instead of the remainder: \(title)")
    }
}

/// Mode without holding in the menu bar.
@MainActor
final class MenuHandsFreeLineTests: XCTestCase {
    func testScenario011() {
        let line = MenuBarStatus.statusLine(
            state: .listening,
            isDictationReady: true,
            isHandsFreeActive: true,
            hotkeyTitle: "Right Command"
        )

        XCTAssertTrue(
            line.contains("Right Command"),
            "The key is released, and the recording continues - the person must find out how to end it: \(line)"
        )
    }

    func testScenario012() {
        let line = MenuBarStatus.statusLine(
            state: .listening,
            isDictationReady: true,
            isHandsFreeActive: false,
            hotkeyTitle: "Right Command"
        )

        XCTAssertEqual(line, "Listening", "The key is pressed - there is nothing to explain")
    }
}

/// Undone work in the first menu line.
///
/// Dictation panel - toast for four seconds. The man who turned away
/// I used to lose both the explanation and the knowledge that the recognized text was still alive. Menu
/// holds it as long as needed.
@MainActor
final class MenuRecoveryLineTests: XCTestCase {
    private func line(text: Bool = false, recording: Bool = false) -> String {
        MenuBarStatus.statusLine(
            state: .idle,
            isDictationReady: true,
            isHandsFreeActive: false,
            hotkeyTitle: "Right Command",
            hasRecoveredText: text,
            hasRecoveredRecording: recording
        )
    }

    func testScenario013() {
        XCTAssertEqual(line(text: true), "Text ready to copy or retry")
    }

    func testScenario014() {
        XCTAssertEqual(line(recording: true), "A recording is waiting to be transcribed")
    }

    /// The text is closer to the result than the record: all that remains is to insert it.
    func testScenario015() {
        XCTAssertEqual(line(text: true, recording: true), line(text: true))
    }

    func testScenario016() {
        XCTAssertEqual(line(), "Ready")
    }

    /// While the dictation is going on, the first line about it is: saved text
    /// will wait until it rests, but you can’t interrupt the live recording with it.
    func testScenario017() {
        let line = MenuBarStatus.statusLine(
            state: .listening,
            isDictationReady: true,
            isHandsFreeActive: false,
            hotkeyTitle: "Right Command",
            hasRecoveredText: true
        )

        XCTAssertEqual(line, "Listening")
    }
}

/// Undone work badge on the menu bar icon.
@MainActor
final class MenuBarBadgeTests: XCTestCase {
    func testScenario018() {
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .idle, isDictationReady: true, hasRecoveredWork: true),
            "waveform.badge.exclamationmark",
            "A person who does not open the menu will otherwise not know about the saved text"
        )
    }

    func testScenario019() {
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .listening, isDictationReady: true, hasRecoveredWork: true),
            "mic.fill",
            "The ongoing recording is more important than the past disaster"
        )
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .transcribing, isDictationReady: true, hasRecoveredWork: true),
            "waveform"
        )
    }

    func testScenario020() {
        // Non-existent SF Symbol name gives an EMPTY icon in the menu bar - worse
        // lack of badge. The test nails the name to the reality of the system.
        let name = MenuBarStatus.iconName(state: .idle, isDictationReady: true, hasRecoveredWork: true)
        XCTAssertNotNil(
            NSImage(systemSymbolName: name, accessibilityDescription: nil),
            "The character '\(name)' does not exist in this version of macOS"
        )
    }

    func testScenario021() {
        for state in [DictationState.idle, .preparing, .listening, .transcribing, .inserting] {
            for ready in [true, false] {
                for recovered in [true, false] {
                    let name = MenuBarStatus.iconName(
                        state: state, isDictationReady: ready, hasRecoveredWork: recovered
                    )
                    XCTAssertNotNil(
                        NSImage(systemSymbolName: name, accessibilityDescription: nil),
                        "The character '\(name)' does not exist"
                    )
                }
            }
        }
    }

    func testScenario022() {
        let label = MenuBarStatus.accessibilityLabel(
            state: .idle, isDictationReady: true, hasRecoveredWork: true
        )
        XCTAssertTrue(label.contains("needs attention"), "A picture without words does not exist for a blind person: \(label)")
    }
}

/// The brand mark in the menu bar, and when it steps aside.
final class MenuBarBrandIconTests: XCTestCase {
    /// At rest the menu bar says whose app this is.
    func testScenario030() {
        XCTAssertTrue(
            MenuBarStatus.usesBrandIcon(state: .idle, isDictationReady: true)
        )
    }

    /// A live microphone outranks the logo. Whether the app is recording has to
    /// be readable at a glance, and a brand mark cannot say it.
    func testScenario031() {
        for state in [DictationState.listening, .transcribing, .inserting, .preparing] {
            XCTAssertFalse(
                MenuBarStatus.usesBrandIcon(state: state, isDictationReady: true),
                "\(state) has something to report"
            )
        }
    }

    /// So does something being wrong, or work left unfinished.
    func testScenario032() {
        XCTAssertFalse(
            MenuBarStatus.usesBrandIcon(state: .idle, isDictationReady: false),
            "dictation is not available — the icon must show it"
        )
        XCTAssertFalse(
            MenuBarStatus.usesBrandIcon(
                state: .idle, isDictationReady: true, hasRecoveredWork: true
            ),
            "unfinished work must stay visible without opening the menu"
        )
    }

    /// The asset name is what SwiftUI looks up; a typo shows an empty icon.
    ///
    /// Loaded from this bundle rather than through `NSImage(named:)`, because
    /// these tests build without a host app — `Bundle.main` is then the xctest
    /// tool, and the lookup would fail for a reason that has nothing to do with
    /// whether the asset ships.
    func testScenario033() {
        XCTAssertEqual(MenuBarStatus.brandIconName, "BrandIconMenuBar")
        XCTAssertNotNil(
            Bundle(for: MenuBarBrandIconTests.self).image(forResource: MenuBarStatus.brandIconName),
            "the asset must be in the bundle, or the menu bar goes blank"
        )
    }

    /// A template asset takes the menu bar's own tint; a non-template one would
    /// stay dark on a dark menu bar.
    func testScenario034() throws {
        let image = try XCTUnwrap(
            Bundle(for: MenuBarBrandIconTests.self).image(forResource: MenuBarStatus.brandIconName)
        )
        XCTAssertTrue(image.isTemplate, "the icon must follow the menu bar's appearance")
    }
}
