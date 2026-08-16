import LocalASR
import XCTest

/// What a person sees about the model in each of its states.
///
/// There are six states, two screens, and previously all six were painted in both
/// places with hands. What is checked here is what is visible: title, explanation,
/// indicator signature and set of buttons.
final class ModelStatusTests: XCTestCase {
    private let ready = ModelState.ready(directory: URL(fileURLWithPath: "/tmp/model"))

    private func status(
        _ state: ModelState,
        place: ModelStatus.Place = .settings,
        engineReady: Bool = true,
        preparing: Bool = false
    ) -> ModelStatus {
        ModelStatus.make(
            state: state,
            place: place,
            isEngineReady: engineReady,
            isPreparingEngine: preparing
        )
    }

    // MARK: - States

    func testScenario001() {
        let status = status(.notInstalled)

        XCTAssertEqual(status.title, "Model not installed")
        XCTAssertEqual(status.actions, [.install])
        // Both models with one button: 483 MB recognition + 103 MB prompt.
        XCTAssertEqual(status.detail?.contains("586 MB"), true)
        XCTAssertNil(status.progress)
    }

    func testScenario002() {
        let status = status(.downloading(receivedBytes: 120_000_000, totalBytes: 483_000_000))

        XCTAssertEqual(status.title, "Downloading model…")
        XCTAssertEqual(status.progressLabel, "120 of 483 MB")
        XCTAssertEqual(status.progress ?? 0, 0.248, accuracy: 0.01)
        // The only action is to honestly stop the download and remove partial.
        XCTAssertEqual(status.actions, [.cancel])
        XCTAssertEqual(status.announcement, "Downloading model")
    }

    func testScenario003() {
        let status = status(.verifying(checked: 3, total: 12))

        XCTAssertEqual(status.title, "Verifying download…")
        XCTAssertEqual(status.progressLabel, "File 3 of 12")
        XCTAssertEqual(status.progress ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(status.actions, [])
        XCTAssertEqual(status.announcement, "Verifying download")
        XCTAssertEqual(
            self.status(.verifying(checked: 11, total: 12)).announcement,
            status.announcement,
            "verification progress must not flood VoiceOver"
        )
    }

    func testScenario004() {
        let status = status(ready, place: .settings)

        XCTAssertEqual(status.title, "Model ready")
        XCTAssertEqual(status.tone, .success)
        XCTAssertEqual(status.actions, [.delete])
    }

    /// There is no delete button in onboarding.
    ///
    /// A person installs the application for the first time; just suggest demolishing
    /// the downloaded 483 MB is the only thing he definitely doesn’t need right now.
    func testScenario005() {
        XCTAssertEqual(status(ready, place: .onboarding).actions, [])
    }

    /// Downloaded is not the same as usable: while the engine is still loading
    /// for this Mac the card says so plainly instead of claiming readiness the
    /// dictation cannot honour yet.
    /// Preparation shows real milestones, and only while it is genuinely
    /// running. Claiming it from readiness alone once stranded a fresh install.
    func testScenario006() {
        let working = ModelStatus.make(
            state: ready,
            preparation: .make(phase: .loadingRecognizer, elapsed: 7),
            place: .settings,
            isEngineReady: false,
            isPreparingEngine: true
        )
        XCTAssertEqual(working.title, "Preparing the model")
        XCTAssertEqual(working.tone, .neutral)
        XCTAssertEqual(working.progressLabel, "Step 1 of 3 · Loading the recognizer… 7 s")
        XCTAssertEqual(working.progress ?? -1, 0, accuracy: 0.001)

        // Nothing running: the card must not narrate work that does not exist.
        let resting = status(ready, engineReady: false)
        XCTAssertEqual(resting.title, "Model ready")
        XCTAssertEqual(resting.tone, .success)
        XCTAssertEqual(resting.detail?.contains("rests until your next dictation"), true)
    }

    func testScenario007() {
        let status = status(.failed(.download("the server did not respond")))

        XCTAssertEqual(status.title, "Model installation failed")
        XCTAssertEqual(status.tone, .failure)
        XCTAssertEqual(status.actions, [.retry])
        XCTAssertEqual(status.detail, "Download failed: the server did not respond")
    }

    func testScenario008() {
        let status = status(.repairRequired("checksum mismatch"))

        XCTAssertEqual(status.title, "Model needs repair")
        XCTAssertEqual(status.actions, [.repair])
        XCTAssertEqual(status.title(for: .repair), "Redownload Model — 586 MB")
        // Addition after update only names the remainder, not the full amount.
        XCTAssertEqual(
            ModelStatus.Action.repair.title(downloadMegabytes: 103),
            "Redownload Model — 103 MB"
        )
        XCTAssertEqual(status.detail?.contains("damaged"), true)
    }

    func testScenario009() {
        let status = status(.deleting)

        XCTAssertEqual(status.title, "Deleting model…")
        XCTAssertEqual(status.actions, [])
        XCTAssertNil(status.progress)
    }

    // MARK: - Errors in words

    /// Lack of space was due to an enumeration dump with raw bytes.
    ///
    /// The person saw `notEnoughDiskSpace(requiredBytes: 594…, availableBytes: 1…)`
    /// and should have guessed that there was no space on the disk.
    func testScenario010() {
        let text = ModelStatus.message(
            for: .notEnoughDiskSpace(requiredBytes: 594_000_000, availableBytes: 120_000_000)
        )

        XCTAssertEqual(
            text,
            "Not enough disk space: 594 MB needed, 120 MB free."
        )
        XCTAssertFalse(text.contains("requiredBytes"))
    }

    func testScenario011() {
        let errors: [ModelStoreError] = [
            .manifest("broken json"),
            .download("no network"),
            .verification("amount did not match"),
            .install("no rights"),
            .repairRequired("no marker"),
            .importSource("wrong folder"),
            .notEnoughDiskSpace(requiredBytes: 1, availableBytes: 0),
            .cancelled,
        ]

        for error in errors {
            let text = ModelStatus.message(for: error)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(
                text.contains("("),
                "'\(text)' looks like an enum dump, not an explanation"
            )
        }
    }

    // MARK: - Announcements

    func testScenario012() {
        let states: [ModelState] = [
            .notInstalled,
            .downloading(receivedBytes: 0, totalBytes: 483_000_000),
            .verifying(checked: 0, total: 12),
            ready,
            .repairRequired("damaged"),
            .failed(.cancelled),
            .deleting,
        ]

        var announcements: Set<String> = []
        for state in states {
            let announcement = status(state).announcement
            XCTAssertFalse(announcement.isEmpty)
            announcements.insert(announcement)
        }
        XCTAssertEqual(announcements.count, states.count, "states should not sound the same")
    }

    // MARK: - Button tooltips

    func testScenario013() {
        for action in [ModelStatus.Action.install, .retry, .repair, .delete] {
            XCTAssertFalse(action.title(downloadMegabytes: 586).isEmpty)
            XCTAssertFalse(action.hint(downloadMegabytes: 586).isEmpty)
        }
        // Deleting is the only irreversible action on the screen, and its cost
        // must be said before pressing.
        XCTAssertEqual(
            ModelStatus.Action.delete.hint(downloadMegabytes: 586).contains("stops working"),
            true
        )
    }

    /// The downloading hint serves the moment: onboarding steers the person to
    /// the permissions below; settings only reassures.
    func testDownloadingDetailNamesTheNextStepOnlyDuringOnboarding() {
        let downloading = ModelState.downloading(receivedBytes: 1_000_000, totalBytes: 483_000_000)
        let onboarding = ModelStatus.make(
            state: downloading, place: .onboarding
        )
        let settings = ModelStatus.make(
            state: downloading, place: .settings
        )

        XCTAssertEqual(
            onboarding.detail,
            "Keep going — grant the permissions below while it downloads."
        )
        XCTAssertEqual(
            settings.detail,
            "You can keep working — the download won't be interrupted."
        )
    }
}
