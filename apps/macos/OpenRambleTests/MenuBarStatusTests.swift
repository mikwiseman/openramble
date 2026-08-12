import AppKit
import LocalASR
import DictationCore
import SwiftUI
import XCTest

/// The menu bar icon is the only persistent presence of the application.
///
/// A picture without a description does not exist at all for a blind person:
/// VoiceOver must still describe the current state even though the branded
/// picture stays stable.
final class MenuBarStatusTests: XCTestCase {
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

    /// The idle line teaches the one gesture the app has.
    func testScenario005() {
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .idle, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Right Command"),
            "Ready — hold Right Command and speak"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .idle, isDictationReady: false, isHandsFreeActive: false, hotkeyTitle: "Right Command"),
            "Setup needed"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .listening, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Fn (🌐)"),
            "Listening"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .inserting, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Fn (🌐)"),
            "Inserting…"
        )
        XCTAssertEqual(
            MenuBarStatus.statusLine(state: .preparing, isDictationReady: true, isHandsFreeActive: false, hotkeyTitle: "Fn (🌐)"),
            "Turning on the microphone…"
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
/// used to lose both the explanation and the knowledge that the recognized text
/// was still alive. The menu holds it as long as needed.
@MainActor
final class MenuRecoveryLineTests: XCTestCase {
    private func line(text: Bool = false) -> String {
        MenuBarStatus.statusLine(
            state: .idle,
            isDictationReady: true,
            isHandsFreeActive: false,
            hotkeyTitle: "Right Command",
            hasRecoveredText: text
        )
    }

    func testScenario013() {
        XCTAssertEqual(line(text: true), "Last dictation wasn't inserted")
    }

    func testScenario016() {
        XCTAssertEqual(line(), "Ready — hold Right Command and speak")
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
    /// The dot never lies: no signal until audio is actually captured.
    func testScenario032() {
        XCTAssertEqual(MenuBarStatus.activity(state: .idle), .hidden)
        XCTAssertEqual(MenuBarStatus.activity(state: .preparing), .hidden)
        XCTAssertEqual(MenuBarStatus.activity(state: .listening), .recording)
        XCTAssertEqual(MenuBarStatus.activity(state: .transcribing), .working)
        XCTAssertEqual(MenuBarStatus.activity(state: .inserting), .working)
    }

    func testScenario033() {
        XCTAssertEqual(MenuBarStatus.badge(activity: .recording), .recording)
        XCTAssertEqual(MenuBarStatus.badge(activity: .working), .working)
        XCTAssertEqual(MenuBarStatus.badge(activity: .hidden), .hidden)
        XCTAssertEqual(
            MenuBarStatus.badge(activity: .hidden, needsAttention: true),
            .attention
        )
        // Attention waits its turn: a live session outranks it, and two
        // signals at once would mean neither is readable.
        XCTAssertEqual(
            MenuBarStatus.badge(activity: .recording, needsAttention: true),
            .recording
        )
        XCTAssertEqual(
            MenuBarStatus.badge(activity: .working, needsAttention: true),
            .working
        )
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
        let preparing = try renderLabel(state: .preparing)
        let recovery = try renderLabel(state: .idle, hasRecoveredWork: true)
        let recording = try renderLabel(state: .listening)
        let processing = try renderLabel(state: .transcribing)

        XCTAssertEqual(preparing, idle, "the dot must not claim recording before audio flows")
        XCTAssertNotEqual(recovery, idle, "recovered work must remain visible after the HUD disappears")
        XCTAssertNotEqual(recording, idle, "recording must add an indicator to the rendered label")
        XCTAssertNotEqual(processing, idle, "processing must add an indicator to the rendered label")
        XCTAssertNotEqual(recording, processing, "recording and processing must render differently")
    }

    @MainActor
    func testScenario036() throws {
        let first = try renderLabel(state: .listening)
        let second = try renderLabel(state: .listening)

        XCTAssertEqual(first, second, "unchanged dictation state must render an identical status item")
    }

    @MainActor
    private func renderLabel(
        state: DictationState,
        hasRecoveredWork: Bool = false
    ) throws -> Data {
        let renderer = ImageRenderer(
            content: MenuBarLabel(
                state: state,
                isDictationReady: true,
                hasRecoveredWork: hasRecoveredWork,
                setupNeedsAttention: false
            )
            .frame(width: 22, height: 22)
        )
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
    }
}

/// The pre-flattened label images that carry color through MenuBarExtra.
///
/// MenuBarExtra template-tints SwiftUI label content, so state colors survive
/// only inside a single non-template NSImage. These assertions pin exactly
/// the properties that keep that mechanism working.
@MainActor
final class MenuBarLabelArtTests: XCTestCase {
    func testScenario037() {
        XCTAssertNil(MenuBarLabelArt.image(badge: .hidden), "rest uses the plain template asset")
        for badge in [MenuBarBadge.recording, .working, .attention] {
            let image = MenuBarLabelArt.image(badge: badge)
            XCTAssertNotNil(image)
            XCTAssertEqual(image?.size, NSSize(width: 22, height: 22))
            XCTAssertEqual(
                image?.isTemplate, false,
                "a template composite would be tinted monochrome and lose the dot color"
            )
        }
    }

    /// Same state — same instance: the label swap costs nothing at render time.
    func testScenario038() {
        XCTAssertTrue(MenuBarLabelArt.image(badge: .recording) === MenuBarLabelArt.image(badge: .recording))
    }
}

/// When does setup genuinely wait on the person.
///
/// True only for states a click can advance. Work in progress — downloads,
/// verification, repair, deletion — must not wear the attention dot, or people
/// learn to ignore it.
final class SetupAttentionTests: XCTestCase {
    private func needsAction(
        accessibility: AccessibilityPermissionState = .granted,
        microphone: Bool = true,
        model: ModelState = .ready(directory: URL(fileURLWithPath: "/tmp/model"))
    ) -> Bool {
        MenuBarStatus.setupNeedsUserAction(
            accessibilityState: accessibility,
            microphoneGranted: microphone,
            modelState: model
        )
    }

    func testScenario040() {
        XCTAssertFalse(needsAction(), "a fully set up app has nothing to ask")
    }

    func testScenario041() {
        XCTAssertTrue(needsAction(accessibility: .denied))
        XCTAssertTrue(needsAction(accessibility: .waitingForSettings))
        XCTAssertTrue(needsAction(accessibility: .restartRequired))
        XCTAssertTrue(needsAction(accessibility: .repairRequired))
        XCTAssertTrue(needsAction(accessibility: .failed("boom")))
        XCTAssertFalse(needsAction(accessibility: .repairing), "repair is running — nothing to click")
    }

    func testScenario042() {
        XCTAssertTrue(needsAction(microphone: false))
    }

    func testScenario043() {
        XCTAssertTrue(needsAction(model: .notInstalled))
        XCTAssertTrue(needsAction(model: .repairRequired("bad file")))
        XCTAssertTrue(needsAction(model: .failed(.download("offline"))))
        XCTAssertFalse(needsAction(model: .downloading(receivedBytes: 1, totalBytes: 2)))
        XCTAssertFalse(needsAction(model: .verifying(checked: 1, total: 2)))
        XCTAssertFalse(needsAction(model: .deleting))
    }
}
