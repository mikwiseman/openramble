import AppKit
import LocalASR
import DictationCore
import SwiftUI
import XCTest

/// The menu bar icon is the only persistent presence of the application.
///
/// A picture without a description does not exist at all for a blind person: VoiceOver
/// must still describe the current state even though the branded picture stays stable.
final class MenuBarStatusTests: XCTestCase {
    func testScenario001() {
        for state in [DictationState.idle, .preparing, .listening, .transcribing, .inserting] {
            XCTAssertEqual(
                MenuBarStatus.iconName(state: state, isDictationReady: true),
                MenuBarStatus.brandIconName,
                "\(state) must keep the OpenRamble identity"
            )
        }
    }

    /// Setup state belongs in the menu copy and accessibility label, not in a
    /// generic microphone glyph that makes OpenRamble impossible to identify.
    func testScenario002() {
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .idle, isDictationReady: false),
            MenuBarStatus.brandIconName
        )
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

/// Recovery state in the stable menu bar identity.
@MainActor
final class MenuBarRecoveryStatusTests: XCTestCase {
    func testScenario018() {
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .idle, isDictationReady: true, hasRecoveredWork: true),
            MenuBarStatus.brandIconName,
            "Recovered work must not replace the only persistent app identity"
        )
    }

    func testScenario019() {
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .listening, isDictationReady: true, hasRecoveredWork: true),
            MenuBarStatus.brandIconName
        )
        XCTAssertEqual(
            MenuBarStatus.iconName(state: .transcribing, isDictationReady: true, hasRecoveredWork: true),
            MenuBarStatus.brandIconName
        )
    }

    func testScenario020() {
        for state in [DictationState.idle, .preparing, .listening, .transcribing, .inserting] {
            for ready in [true, false] {
                for recovered in [true, false] {
                    let name = MenuBarStatus.iconName(
                        state: state, isDictationReady: ready, hasRecoveredWork: recovered
                    )
                    XCTAssertEqual(name, MenuBarStatus.brandIconName)
                }
            }
        }
    }

    func testScenario021() {
        let label = MenuBarStatus.accessibilityLabel(
            state: .idle, isDictationReady: true, hasRecoveredWork: true
        )
        XCTAssertTrue(label.contains("needs attention"), "A picture without words does not exist for a blind person: \(label)")
    }
}

/// The brand mark in the menu bar.
final class MenuBarBrandIconTests: XCTestCase {
    /// The asset name is what SwiftUI looks up; a typo shows an empty icon.
    ///
    /// Loaded from this bundle rather than through `NSImage(named:)`, because
    /// these tests build without a host app — `Bundle.main` is then the xctest
    /// tool, and the lookup would fail for a reason that has nothing to do with
    /// whether the asset ships.
    func testScenario030() {
        XCTAssertEqual(MenuBarStatus.brandIconName, "BrandIconMenuBar")
        XCTAssertNotNil(
            Bundle(for: MenuBarBrandIconTests.self).image(forResource: MenuBarStatus.brandIconName),
            "the asset must be in the bundle, or the menu bar goes blank"
        )
    }

    /// A template asset takes the menu bar's own tint; a non-template one would
    /// stay dark on a dark menu bar.
    func testScenario031() throws {
        let image = try XCTUnwrap(
            Bundle(for: MenuBarBrandIconTests.self).image(forResource: MenuBarStatus.brandIconName)
        )
        XCTAssertTrue(image.isTemplate, "the icon must follow the menu bar's appearance")
    }
}

final class MenuBarActivityTests: XCTestCase {
    func testScenario032() {
        XCTAssertEqual(MenuBarStatus.activity(state: .idle), .hidden)
        XCTAssertEqual(MenuBarStatus.activity(state: .preparing), .hidden)
        XCTAssertEqual(MenuBarStatus.activity(state: .listening), .recording)
        XCTAssertEqual(MenuBarStatus.activity(state: .transcribing), .processing)
        XCTAssertEqual(MenuBarStatus.activity(state: .inserting), .processing)
    }

    func testScenario033() {
        XCTAssertEqual(MenuBarStatus.color(activity: .recording), .blue)
        XCTAssertEqual(MenuBarStatus.color(activity: .processing), .green)
        XCTAssertEqual(MenuBarStatus.color(activity: .hidden), .clear)
    }

    func testScenario034() {
        XCTAssertEqual(
            MenuBarStatus.accessibilityLabel(
                state: .idle,
                isDictationReady: true
            ),
            "OpenRamble: ready to dictate"
        )
    }

    @MainActor
    func testScenario035() throws {
        let idle = try renderLabel(state: .idle)
        let recording = try renderLabel(state: .listening)
        let processing = try renderLabel(state: .transcribing)

        XCTAssertNotEqual(recording, idle, "recording must add an indicator to the rendered label")
        XCTAssertNotEqual(processing, idle, "processing must add an indicator to the rendered label")
        XCTAssertNotEqual(recording, processing, "recording and processing must render different colors")
    }

    func testScenario036() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenRamble/UI/MenuBarLabel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("TimelineView"), "the system status item must not redraw on a timeline")
        XCTAssertFalse(source.contains("Timer"), "the system status item must not own a repeating timer")
        XCTAssertFalse(source.contains("Task.sleep"), "the system status item must not schedule delayed redraws")
    }

    @MainActor
    private func renderLabel(state: DictationState) throws -> Data {
        let renderer = ImageRenderer(
            content: MenuBarLabel(
                state: state,
                isDictationReady: true,
                hasRecoveredWork: false
            )
            .frame(width: 22, height: 22)
        )
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
    }
}
