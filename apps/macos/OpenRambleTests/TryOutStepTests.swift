import DictationCore
import LocalASR
import XCTest

/// The step the setup gate now opens onto, while the first load is still running.
///
/// Removing the engine from the setup gate was right — nothing was preparing an
/// engine the screen was waiting for — but it moved the person one screen
/// further along, onto a step whose entire instruction is "hold the key". For
/// the one-time compile after a fresh install that press is refused: recording
/// never starts, and the person is left with a screen that says "hold the key,
/// say a few words" and a footer that says "try dictation first". Both
/// sentences are false for as long as the compile lasts.
///
/// This is not a deadlock — the compile ends by itself, and "Skip the try-out"
/// is right there — so the fix is not another gate. It is the second half of the
/// bar: a screen held by work in motion has to say truthfully what that work is.
/// The words already exist, in the sentence the key press itself produces, so
/// the screen says that one rather than inventing a second opinion.
@MainActor
final class TryOutStepTests: XCTestCase {
    private let ready = ModelState.ready(directory: URL(fileURLWithPath: "/tmp/model"))
    private let firstLoad =
        "The model is getting ready for this Mac — usually 20–40 seconds, and only once."

    // MARK: - The footer says what the key press would say

    func testTheTryOutFooterNamesTheLoadThatIsRefusingTheKeyPress() {
        XCTAssertEqual(
            OnboardingGate.blockReason(
                step: .tryIt,
                conditions: OnboardingConditions(
                    microphoneGranted: true,
                    accessibilityGranted: true,
                    modelState: ready,
                    trialSucceeded: false,
                    dictationRefusal: firstLoad
                )
            ),
            firstLoad,
            "the step asks for a press that would be refused, and says why"
        )
    }

    /// Once a take has landed, a cold engine is nothing to mention.
    ///
    /// Residency may give the memory back between the trial and the button, and
    /// that engine's comeback really is the next key press. Naming it there
    /// would be the resting engine's own false alarm, one screen later.
    func testATrialThatAlreadySucceededIsNotHeldByAnythingAtAll() {
        XCTAssertNil(
            OnboardingGate.blockReason(
                step: .tryIt,
                conditions: OnboardingConditions(
                    microphoneGranted: true,
                    accessibilityGranted: true,
                    modelState: ready,
                    trialSucceeded: true,
                    dictationRefusal: firstLoad
                )
            )
        )
    }

    /// With the engine loaded, the step asks for the one thing it is for.
    func testWithoutARefusalTheStepStillAsksForTheTrial() {
        XCTAssertEqual(
            OnboardingGate.blockReason(
                step: .tryIt,
                conditions: OnboardingConditions(
                    microphoneGranted: true,
                    accessibilityGranted: true,
                    modelState: ready,
                    trialSucceeded: false
                )
            ),
            "Try dictation first, or press “Skip the try-out”."
        )
    }

    // MARK: - It is a sentence, never a gate

    /// Nothing here may decide whether a button is alive.
    ///
    /// This is the whole difference between saying what is happening and
    /// waiting for it. The engine requirement stranded two releases because it
    /// could disable Continue; a refusal that only ever replaces one sentence
    /// with a truer one cannot strand anything. Checked for every step and every
    /// combination, so it stays that way.
    func testAKeyPressRefusalNeverChangesWhetherAStepCanAdvance() {
        let states: [ModelState] = [ready, .notInstalled, .downloading(receivedBytes: 1, totalBytes: 2)]
        for step in OnboardingStep.allCases {
            for microphone in [true, false] {
                for accessibility in [true, false] {
                    for model in states {
                        for trial in [true, false] {
                            func advance(_ refusal: String?) -> Bool {
                                OnboardingGate.canAdvance(
                                    step: step,
                                    conditions: OnboardingConditions(
                                        microphoneGranted: microphone,
                                        accessibilityGranted: accessibility,
                                        modelState: model,
                                        trialSucceeded: trial,
                                        dictationRefusal: refusal
                                    )
                                )
                            }
                            XCTAssertEqual(
                                advance(firstLoad),
                                advance(nil),
                                """
                                step=\(step) microphone=\(microphone) \
                                accessibility=\(accessibility) model=\(model) trial=\(trial): \
                                a refused key press changed whether the button is alive.
                                """
                            )
                        }
                    }
                }
            }
        }
    }

    /// The setup step never hears about the engine again.
    ///
    /// It is the screen from the photograph, and the requirement that stranded
    /// it is gone. A refusal reaching it would put it straight back — this time
    /// through a field rather than a parameter.
    func testTheSetupStepIsNeverHeldByARefusedKeyPress() {
        XCTAssertNil(
            OnboardingGate.blockReason(
                step: .setup,
                conditions: OnboardingConditions(
                    microphoneGranted: true,
                    accessibilityGranted: true,
                    modelState: ready,
                    dictationRefusal: firstLoad
                )
            ),
            "the files are usable and both permissions are granted; nothing else is its business"
        )
    }

    // MARK: - The running app

    /// The whole window, over a real `AppState`, for the length of a real load.
    ///
    /// The recognizer here holds its first `prepare` open exactly as the
    /// one-time Core ML compile does. Everything the try-out step shows is read
    /// off the app through the same two calls `OnboardingView` makes, so the
    /// test cannot pass on a screen the app would not draw: while the load runs
    /// the screen names it, and when the load ends by itself the screen goes
    /// back to asking for the trial.
    func testTheTryOutScreenNarratesTheFirstLoadAndStopsWhenItEnds() async throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        harness.permissions.microphoneGranted = true
        harness.permissions.accessibilityGranted = true
        let recognizer = SlowFirstLoadRecognizer()
        harness.recognizer = recognizer
        try harness.installModelMarker()

        let state = harness.makeState()
        let screen = TryOutScreen(state: state)
        try await waitUntil("the first load is visibly running") { state.isPreparingEngine }
        XCTAssertFalse(state.hasEngineBeenReady, "this is the load that has never finished")
        XCTAssertFalse(
            state.isDictationReady,
            "a key press right now is refused — that is what the screen has to say"
        )

        XCTAssertEqual(screen.footer, firstLoad)
        XCTAssertEqual(
            screen.statusLine,
            "Preparing the model — Step 1 of 3 · \(state.enginePreparation.title)",
            "the step shows the same live milestone the setup screen shows"
        )

        // Nothing is asked of the person: the load finishes on its own.
        await recognizer.finishLoading()
        try await waitUntil("the engine finishes loading") { state.isEngineReady }

        XCTAssertEqual(screen.footer, "Try dictation first, or press “Skip the try-out”.")
        XCTAssertNil(screen.statusLine, "a loaded engine is nothing to narrate")
        XCTAssertTrue(state.isDictationReady)
    }

    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting until \(what)", file: file, line: line)
    }
}

/// The try-out step as the person sees it: one status line, one footer.
@MainActor
private struct TryOutScreen {
    let state: AppState

    /// The same card the setup step draws, asked for its one-line form.
    var statusLine: String? {
        ModelStatus.make(
            state: state.modelState,
            preparation: state.enginePreparation,
            place: .onboarding,
            downloadMegabytes: state.remainingDownloadMegabytes,
            isEngineReady: state.isEngineReady,
            isPreparingEngine: state.isPreparingEngine
        ).setupLine
    }

    /// Read off the app by the app's own reader, never assembled here.
    var footer: String? {
        OnboardingGate.blockReason(
            step: .tryIt,
            conditions: OnboardingConditions(state: state, trialSucceeded: false)
        )
    }
}

/// A recognizer whose first load lasts as long as the test wants it to.
///
/// The one cost a first run cannot avoid is the one-time compile, and no
/// existing fake spends it: they all answer instantly, so every test so far has
/// measured a first run in which the engine is ready before the person has
/// finished reading the screen.
private actor SlowFirstLoadRecognizer: DictationRecognizing {
    private var prepared = false
    private var loadFinished = false
    private var observer: AsyncStream<Bool>.Continuation?

    var isPrepared: Bool { prepared }
    var isBusy: Bool { false }

    func readinessChanges() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            observer = continuation
            continuation.yield(prepared)
        }
    }

    func finishLoading() { loadFinished = true }

    func prepare(modelDirectory: URL) async throws {
        while !loadFinished {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func prepareVocabulary(modelDirectory: URL, boost: VocabularyBoost) async throws {}

    func transcribe(fileURL: URL, languageHint: String?) async throws -> ASRResult {
        ASRResult(text: "", audioDuration: 1, processingDuration: 0)
    }

    func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult {
        ASRResult(text: "", audioDuration: 1, processingDuration: 0)
    }

    func warmUpInference() async throws {
        prepared = true
        observer?.yield(true)
    }

    func unload() async {
        prepared = false
        observer?.yield(false)
    }

    func unloadIfIdle() async -> Bool {
        await unload()
        return true
    }
}
