import LocalASR
import XCTest

/// Onboarding is the only way for a new person to get to a working product.
///
/// It is not checked whether the step has been switched, but what a person will see at this step:
/// will the button allow him further and will he be told what is missing.
final class OnboardingStepTests: XCTestCase {
    private let ready = ModelState.ready(directory: URL(fileURLWithPath: "/tmp/model"))

    private func conditions(
        microphone: Bool = true,
        accessibility: Bool = true,
        model: ModelState? = nil,
        dictationBusy: Bool = false,
        trialSucceeded: Bool = true
    ) -> OnboardingConditions {
        OnboardingConditions(
            microphoneGranted: microphone,
            accessibilityGranted: accessibility,
            modelState: model ?? ready,
            isDictationBusy: dictationBusy,
            trialSucceeded: trialSucceeded
        )
    }

    private func reason(
        _ step: OnboardingStep,
        microphone: Bool = true,
        accessibility: Bool = true,
        model: ModelState? = nil,
        dictationBusy: Bool = false,
        trialSucceeded: Bool = true
    ) -> String? {
        OnboardingGate.blockReason(
            step: step,
            conditions: conditions(
                microphone: microphone,
                accessibility: accessibility,
                model: model,
                dictationBusy: dictationBusy,
                trialSucceeded: trialSucceeded
            )
        )
    }

    // MARK: - Steps

    func testScenario001() {
        XCTAssertEqual(OnboardingStep.allCases.count, 3)
        XCTAssertEqual(OnboardingStep.welcome.next, .setup)
        XCTAssertEqual(OnboardingStep.setup.next, .tryIt)
        XCTAssertNil(OnboardingStep.tryIt.next)
    }

    /// There is no “Back” button at all on the first step.
    ///
    /// A disabled button looks like it's broken, and pressing it would lead to nowhere.
    func testScenario002() {
        XCTAssertFalse(OnboardingStep.welcome.hasPrevious)
        XCTAssertNil(OnboardingStep.welcome.previous)

        XCTAssertTrue(OnboardingStep.setup.hasPrevious)
        XCTAssertEqual(OnboardingStep.setup.previous, .welcome)
        XCTAssertEqual(OnboardingStep.tryIt.previous, .setup)
    }

    func testScenario003() {
        XCTAssertEqual(OnboardingStep.welcome.nextButtonTitle, "Continue")
        XCTAssertEqual(OnboardingStep.setup.nextButtonTitle, "Continue")
        XCTAssertEqual(OnboardingStep.tryIt.nextButtonTitle, "Done")
    }

    func testScenario004() {
        XCTAssertEqual(OnboardingStep.welcome.progressText, "1 of 3")
        XCTAssertEqual(OnboardingStep.tryIt.progressText, "3 of 3")
        // "1 of 3" without the word "step" VoiceOver reads like a couple of numbers out of nowhere.
        XCTAssertEqual(OnboardingStep.welcome.progressAccessibilityLabel, "Step 1 of 3")
        XCTAssertEqual(OnboardingStep.tryIt.progressAccessibilityLabel, "Step 3 of 3")
    }

    // MARK: - Who lets in next

    func testScenario005() {
        XCTAssertNil(reason(.welcome, microphone: false, accessibility: false, model: .notInstalled))
    }

    func testScenario006() {
        XCTAssertEqual(
            reason(.tryIt, trialSucceeded: false),
            "Try dictation first, or press “Skip the try-out”."
        )
        XCTAssertNil(reason(.tryIt, trialSucceeded: true))
    }

    // MARK: - Permissions

    func testScenario007() {
        let text = reason(.setup, microphone: false, accessibility: false)
        XCTAssertEqual(text, "Two permissions left to grant — Microphone and Accessibility.")
    }

    func testScenario008() {
        XCTAssertEqual(reason(.setup, microphone: false, accessibility: true), "Microphone is still needed.")
    }

    func testScenario009() {
        XCTAssertEqual(
            reason(.setup, microphone: true, accessibility: false),
            "Accessibility is still needed."
        )
    }

    func testScenario010() {
        XCTAssertNil(reason(.setup, microphone: true, accessibility: true))
        XCTAssertTrue(
            OnboardingGate.canAdvance(step: .setup, conditions: conditions())
        )
    }

    // MARK: - A running take

    /// A running take is the one thing that speaks over the step's own reason.
    ///
    /// It ends by itself, or by the "Cancel Dictation" button standing next to
    /// the disabled one — so it is a legitimate thing to be held by.
    func testARunningDictationOutranksEveryStepsOwnReason() {
        for step in OnboardingStep.allCases {
            XCTAssertEqual(
                reason(step, dictationBusy: true),
                "Finish or cancel the current dictation first."
            )
        }
    }

    // MARK: - Model

    func testScenario011() {
        XCTAssertEqual(
            reason(.setup, model: .notInstalled),
            "Download the model first — without it there is nothing to recognize with."
        )
        XCTAssertEqual(
            reason(.setup, model: .downloading(receivedBytes: 1, totalBytes: 2)),
            "Wait for the download to finish."
        )
        XCTAssertEqual(
            reason(.setup, model: .verifying(checked: 1, total: 12)),
            "The download is being verified."
        )
        XCTAssertEqual(
            reason(.setup, model: .failed(.download("no network"))),
            "The download failed. Try again."
        )
        XCTAssertEqual(reason(.setup, model: .deleting), "The model is being deleted.")
    }

    /// Usable files are the whole model requirement.
    ///
    /// The gate is not told whether the engine is loaded, and must not be: the
    /// engine is loaded and unloaded by residency, and a resting one waits for
    /// a key press that nobody makes on this screen. Every input here either
    /// moves by itself or is the person's to change.
    func testScenario012() {
        XCTAssertNil(reason(.setup, model: ready))
    }

    /// At no point is a disabled button left without explanation.
    ///
    /// This is precisely the dead end of the attitude: a person sees a dead “Next” and does not
    /// knows what they want from him, but the blind man does not see it either.
    func testScenario014() {
        let states: [ModelState] = [
            .notInstalled,
            .downloading(receivedBytes: 0, totalBytes: 1),
            .verifying(checked: 0, total: 1),
            .repairRequired("damaged"),
            .failed(.cancelled),
            .deleting,
            ready,
        ]

        for step in OnboardingStep.allCases {
            for microphone in [true, false] {
                for accessibility in [true, false] {
                    for model in states {
                        let facts = conditions(
                            microphone: microphone,
                            accessibility: accessibility,
                            model: model
                        )
                        let blocked = !OnboardingGate.canAdvance(step: step, conditions: facts)
                        let text = OnboardingGate.blockReason(step: step, conditions: facts)
                        XCTAssertEqual(
                            blocked,
                            text?.isEmpty == false,
                            "step \(step) must explain why it doesn't let in"
                        )
                    }
                }
            }
        }
    }
}
