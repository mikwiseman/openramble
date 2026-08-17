import DictationCore
import LocalASR
import XCTest

/// The bar a first run has to clear, written down so a machine can check it.
///
/// A person installs OpenRamble, and without ever quitting it reaches working
/// dictation — however long they take, in whatever order they grant the two
/// permissions, and whatever the residency policy decides about memory while
/// they are away in System Settings.
///
/// So at every instant the setup step is allowed to be in exactly two
/// conditions:
///
///   A. it can advance, or
///   B. it is blocked by something genuinely in motion, which will finish on
///      its own and then let it advance.
///
/// These tests check A and B with one measurement, because in this harness
/// every real cost is instant: the recognizer answers immediately, the retry
/// ladder waits ten milliseconds, and the model is already on disk. Anything
/// genuinely in motion therefore finishes inside the budget, and a screen still
/// blocked at the end of it was waiting for work nobody was doing. That is the
/// failure the person photographed — "Model ready" over "Getting the model
/// ready…", with the Continue button greyed out and only ⌘Q to fix it.
///
/// Nothing here mocks the thing under test. The screen is assembled from the
/// same two calls `OnboardingView` makes — `ModelStatus.make` for the card and
/// `OnboardingGate.blockReason` for the footer and the button — over a real
/// `AppState` driven through the real first-run sequence.
@MainActor
final class SetupScreenBarTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
        harness = nil
    }

    // MARK: - The photographed failure

    /// The screenshot, reproduced through the events that produce it.
    ///
    /// The download finished and the engine loaded. The person left for System
    /// Settings to grant the microphone and Accessibility. While they were
    /// away, macOS reported critical memory pressure — the ordinary
    /// consequence of having just written 586 MB and loaded a 2.4 GB model —
    /// and the app gave the memory back, which is the right call. They came
    /// back with both permissions granted.
    ///
    /// Now the card says "Model ready — the model rests until your next
    /// dictation", the footer says "Getting the model ready…", and Continue is
    /// grey. The dictation that would wake the engine is the one this very
    /// screen exists to enable. Nothing is running, and nothing will start.
    func testSetupAdvancesAfterMemoryPressureUnloadsTheEngineDuringSetup() async throws {
        harness.permissions.microphoneGranted = false
        harness.permissions.accessibilityGranted = false
        let recognizer = ReadinessControlledRecognizer()
        harness.recognizer = recognizer
        try harness.installModelMarker()

        let state = harness.makeState()
        let screen = SetupScreen(state: state)
        try await waitUntil("the install-time preparation finishes") { state.isEngineReady }

        // macOS asks for the memory back while the person is away.
        state.registerMemoryPressure(.critical)
        try await waitUntil("the engine gives its memory back") { !state.isEngineReady }

        // They come back from System Settings with both permissions granted.
        harness.permissions.microphoneGranted = true
        harness.permissions.accessibilityGranted = true
        state.refreshPermissions()
        XCTAssertTrue(state.microphoneGranted)
        XCTAssertTrue(state.accessibilityGranted)

        await assertSetupClearsTheBar(screen)
    }

    /// The same picture with no residency decision behind it: the worker died.
    ///
    /// A 2.4 GB child process on a Mac that has just written 586 MB is a jetsam
    /// candidate, and the worker is the authority on readiness — when it stops
    /// being ready the app hears about it. Nobody decided to rest here; the app
    /// still wants a loaded engine. The setup screen must not be the place
    /// where that want goes unheard.
    func testSetupAdvancesAfterTheWorkerStopsBeingReadyDuringSetup() async throws {
        harness.permissions.microphoneGranted = true
        harness.permissions.accessibilityGranted = false
        let recognizer = ReadinessControlledRecognizer()
        harness.recognizer = recognizer
        try harness.installModelMarker()

        let state = harness.makeState()
        let screen = SetupScreen(state: state)
        try await waitUntil("the install-time preparation finishes") { state.isEngineReady }

        // The worker process is gone. No policy chose this.
        await recognizer.setReady(false)
        try await waitUntil("the app hears the readiness drop") { !state.isEngineReady }

        // Accessibility is granted afterwards, which is the common order.
        harness.permissions.accessibilityGranted = true
        state.refreshPermissions()

        await assertSetupClearsTheBar(screen)
    }

    // MARK: - Awkward orderings

    /// The long stay: the setup window is open longer than the idle timer.
    ///
    /// Reopened setup is ordinary — "Finish Setting Up…" in the menu, or
    /// Window ▸ Welcome, both of which put this exact screen back in front of a
    /// person whose defaults already say onboarding was completed once. The
    /// idle-unload countdown runs against a screen where nobody dictates, so it
    /// always wins, and the engine's stated comeback is a key press that this
    /// screen is the reason nobody makes.
    ///
    /// Only the countdown is shortened here. The decision that ends it is the
    /// product's own.
    func testSetupAdvancesAfterTheIdleTimerUnloadsTheEngineOnTheSetupScreen() async throws {
        harness.defaults.set(true, forKey: AppState.onboardingCompletedKey)
        harness.idleUnloadDelayOverride = .milliseconds(20)
        harness.permissions.microphoneGranted = true
        harness.permissions.accessibilityGranted = true
        let recognizer = ReadinessControlledRecognizer()
        harness.recognizer = recognizer
        try harness.installModelMarker()

        let state = harness.makeState()
        let screen = SetupScreen(state: state)
        try await waitUntil("the engine loads") { state.isEngineReady }

        // The person is reading the setup screen. Nothing is dictated.
        try await waitUntil("the idle timer gives the memory back") { !state.isEngineReady }

        await assertSetupClearsTheBar(screen)
    }

    /// Both permissions granted first, the model afterwards — the other order.
    ///
    /// Readiness does not only arrive from the two events that start
    /// preparation. It also arrives from a plain look at the disk: the Settings
    /// window refreshes model state whenever it opens, and a finished install
    /// whose terminal state the app re-reads lands the same way. The standing
    /// rule the app documents — files ready, engine cold, nothing running,
    /// so start — has to hold for readiness however it arrives, or the screen
    /// is left waiting on a rule that only fires at launch and at the end of
    /// one particular install path.
    func testSetupAdvancesWhenReadinessArrivesFromADiskRefresh() async throws {
        harness.permissions.microphoneGranted = true
        harness.permissions.accessibilityGranted = true
        let recognizer = ReadinessControlledRecognizer()
        harness.recognizer = recognizer
        // Nothing on disk: this run starts before the download, exactly as a
        // wiped Mac does.

        let state = harness.makeState()
        let screen = SetupScreen(state: state)
        try await settleLaunch(state: state, recognizer: recognizer)
        XCTAssertFalse(state.modelState.isReady, "the run starts with no model on disk")
        XCTAssertEqual(
            screen.footer,
            "Download the model first — without it there is nothing to recognize with.",
            "before the download the screen blocks on the person, which is honest"
        )

        // The model becomes usable, and the app learns it the same way the
        // Settings window does.
        try harness.installModelMarker()
        await state.refreshModelState()
        XCTAssertTrue(state.modelState.isReady, "the files are usable now")

        await assertSetupClearsTheBar(screen)
    }

    /// The whole first run in one sequence, in the order it actually happens.
    ///
    /// Launch with nothing on disk; the model arrives; the microphone is
    /// granted; a long trip to System Settings for Accessibility, during which
    /// the machine runs short of memory and the engine is unloaded; and then
    /// the person comes back. Each step is legitimate. The end of the sequence
    /// must be a screen that lets them through.
    func testTheWholeFirstRunReachesAnAdvancingSetupScreen() async throws {
        harness.permissions.microphoneGranted = false
        harness.permissions.accessibilityGranted = false
        let recognizer = ReadinessControlledRecognizer()
        harness.recognizer = recognizer

        let state = harness.makeState()
        let screen = SetupScreen(state: state)
        try await settleLaunch(state: state, recognizer: recognizer)

        // The download finishes and the app reads the result.
        try harness.installModelMarker()
        await state.refreshModelState()

        // The microphone is granted first.
        harness.permissions.microphoneGranted = true
        state.refreshPermissions()

        // The trip to System Settings for Accessibility is long, and the Mac
        // is under memory pressure while it lasts.
        state.registerMemoryPressure(.critical)
        try? await Task.sleep(for: .milliseconds(50))

        harness.permissions.accessibilityGranted = true
        state.refreshPermissions()

        await assertSetupClearsTheBar(screen)
    }

    /// The one way out of a rejected model has to name what it will cost.
    ///
    /// Core ML refusing the model is a legitimate block: the screen says so and
    /// offers a button, and the person can press it — condition B, with a person
    /// rather than a timer as the thing in motion. But the button was labelled
    /// "Redownload Model — 0 MB", because the number is computed from what is
    /// missing from disk and nothing is missing: the files are intact, the model
    /// would not load, and the repair redownloads both models anyway. Nobody
    /// decides about hotel Wi-Fi with a 0.
    func testTheRepairOfferedOnTheSetupScreenNamesItsRealDownload() async throws {
        harness.permissions.microphoneGranted = true
        harness.permissions.accessibilityGranted = true
        harness.warmUpEngine = FailingASREngine()
        try harness.installModelMarker()

        let state = harness.makeState()
        let screen = SetupScreen(state: state)
        try await waitUntil("Core ML rejects the intact files") {
            state.modelState.requiresRepair
        }

        XCTAssertEqual(
            screen.footer,
            "The model is damaged. Redownload it explicitly.",
            "the block is real and the person owns it"
        )
        XCTAssertEqual(screen.card.actions, [.repair], "one control, and it is the way out")
        XCTAssertEqual(
            screen.card.title(for: .repair),
            "Redownload Model — 586 MB",
            "the repair fetches both models again, and the button says how much that is"
        )
    }

    // MARK: - The card and the footer describe one instant

    /// Two views of one moment must not say opposite things about it.
    ///
    /// The card and the gate used to be handed the same two facts and reach
    /// opposite conclusions from them: with a ready model, a cold engine and no
    /// preparation running, the card said the model is ready and resting, and
    /// the footer said the model is being got ready. Both cannot be true, and
    /// the person is looking at both at once. The card still reads the engine —
    /// it is describing the model, and a resting engine is worth saying — while
    /// the gate no longer does, so whatever the card reports, the footer has
    /// nothing to contradict it with.
    func testTheCardNeverCallsTheModelReadyWhileTheFooterAsksToWaitForIt() {
        let ready = ModelState.ready(directory: URL(fileURLWithPath: "/tmp/model"))
        for engineReady in [false, true] {
            for enginePreparing in [false, true] {
                let card = ModelStatus.make(
                    state: ready,
                    preparation: .make(phase: .idle, elapsed: 0),
                    place: .onboarding,
                    isEngineReady: engineReady,
                    isPreparingEngine: enginePreparing
                )
                let footer = OnboardingGate.blockReason(
                    step: .setup,
                    conditions: OnboardingConditions(
                        microphoneGranted: true,
                        accessibilityGranted: true,
                        modelState: ready
                    )
                )
                let footerWaitsOnTheEngine = footer.map(
                    SetupScreen.engineWaitSentences.contains
                ) ?? false

                XCTAssertFalse(
                    card.tone == .success && footerWaitsOnTheEngine,
                    """
                    isEngineReady=\(engineReady) isPreparingEngine=\(enginePreparing): \
                    the card says “\(card.title)” — “\(card.detail ?? "")” while the \
                    footer says “\(footer ?? "")” and Continue is disabled. \
                    One screen, one instant, two opposite claims.
                    """
                )
            }
        }
    }

    /// The menu is a first-run surface too, and it must not contradict the card.
    ///
    /// `setupHints` is shown exactly while a permission is still missing — the
    /// setup phase, the same minutes the screenshot was taken in. The menu used
    /// to decide this line for itself, from a ready model and a cold engine
    /// alone, and so it announced "Preparing the model for dictation…" about an
    /// engine residency had put to rest with nothing running: the photographed
    /// defect, one file away from where it was fixed. Whatever the menu says
    /// about the model is now said by the card type, which is handed all three
    /// facts and has told the truth since 0.8.2.
    func testTheMenuNeverNarratesPreparationThatIsNotHappening() {
        let ready = ModelState.ready(directory: URL(fileURLWithPath: "/tmp/model"))

        let resting = ModelStatus.make(
            state: ready,
            preparation: .make(phase: .idle, elapsed: 0),
            place: .settings,
            isEngineReady: false,
            isPreparingEngine: false
        )
        XCTAssertNil(
            resting.setupLine,
            """
            The menu says “\(resting.setupLine ?? "")” about an engine that is \
            resting with nothing running, while the card next to it says \
            “\(resting.title)” — “\(resting.detail ?? "")”.
            """
        )

        let loaded = ModelStatus.make(
            state: ready,
            place: .settings,
            isEngineReady: true,
            isPreparingEngine: false
        )
        XCTAssertNil(loaded.setupLine, "a loaded engine asks nothing of anyone")

        // The one moment the menu does speak about preparation is the one where
        // preparation is running, and then it names the step it is on.
        let preparing = ModelStatus.make(
            state: ready,
            preparation: .make(phase: .loadingRecognizer, elapsed: 1),
            place: .settings,
            isEngineReady: false,
            isPreparingEngine: true
        )
        XCTAssertEqual(
            preparing.setupLine,
            "Preparing the model — Step 1 of 3 · Loading the recognizer… 1 s"
        )

        // Everything the person must act on still has its line and its button.
        let missing = ModelStatus.make(state: .notInstalled, place: .settings, downloadMegabytes: 586)
        XCTAssertEqual(missing.setupLine, "Model not installed")
        XCTAssertEqual(missing.actions, [.install])
    }

    // MARK: - The bar itself

    /// Condition A or condition B, measured as one thing.
    private func assertSetupClearsTheBar(
        _ screen: SetupScreen,
        within budget: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + budget
        while clock.now < deadline {
            // Both, in one wait. The screen can open the way through the instant
            // the files become usable while the first engine load is still
            // running — which is legitimate, the try-out says so in words and it
            // ends by itself — so waiting only for the button would time the two
            // halves of the first run against different clocks.
            if screen.canAdvance, screen.state.isDictationReady { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(
            screen.canAdvance,
            """
            The setup screen spent \(budget) unable to advance, waiting for work \
            nobody is doing. Only quitting the app clears this.
            \(screen.report)
            """,
            file: file,
            line: line
        )

        XCTAssertFalse(
            screen.cardAndFooterContradict,
            """
            The card and the footer describe the same instant and disagree about it.
            \(screen.report)
            """,
            file: file,
            line: line
        )

        // Letting them past the screen is only half of a first run. The next
        // thing they do is hold the key, and the app's own readiness — the same
        // predicate that decides whether the menu still shows setup hints — has
        // to accept it. Otherwise the deadlock simply moved one screen later.
        XCTAssertTrue(
            screen.state.isDictationReady,
            """
            The setup screen let them through to a try-out that will refuse the key press.
            \(screen.report)
            """,
            file: file,
            line: line
        )
    }

    // MARK: - Helpers

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

    /// Let the launch task finish before the test changes the world under it.
    ///
    /// Launch reads the disk and then applies the standing preparation rule
    /// once. A test that installs the model while that is still in flight would
    /// be measuring the launch path instead of the one it means to measure.
    private func settleLaunch(
        state: AppState,
        recognizer: ReadinessControlledRecognizer
    ) async throws {
        for _ in 0..<60 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(state.isEngineReady, "nothing to prepare before the model exists")
        let prepares = await recognizer.prepares
        XCTAssertEqual(prepares, 0, "the engine was not asked to load a model that is not there")
    }
}

/// The setup step as the person sees it: one card, one footer, one button.
///
/// Built from the two calls `OnboardingView` makes, so the test cannot pass on
/// a screen the app would not actually draw.
@MainActor
private struct SetupScreen {
    let state: AppState

    var card: ModelStatus {
        ModelStatus.make(
            state: state.modelState,
            preparation: state.enginePreparation,
            place: .onboarding,
            downloadMegabytes: state.remainingDownloadMegabytes,
            isEngineReady: state.isEngineReady,
            isPreparingEngine: state.isPreparingEngine
        )
    }

    /// Read off the app by the app's own reader, never assembled here.
    ///
    /// This is the whole difference between a bar and a decoration. When the
    /// test filled in the gate's arguments itself, the engine requirement that
    /// stranded 0.8.1 and 0.8.2 could sit in a defaulted parameter the test
    /// never passed — and all six scenarios below passed against the very build
    /// that produced the screenshot. Going through `OnboardingConditions`
    /// means a fact the app consults is a fact this test consults.
    var footer: String? {
        OnboardingGate.blockReason(
            step: .setup,
            conditions: OnboardingConditions(state: state, trialSucceeded: true)
        )
    }

    /// The Continue button is `.disabled(navigationBlockReason != nil)`.
    var canAdvance: Bool { footer == nil }

    /// The two sentences that waited on the app rather than on the person.
    ///
    /// The gate no longer has an engine to wait for, so these are kept as the
    /// shape of the failure: if a footer ever says one of them again, the
    /// requirement has come back.
    static let engineWaitSentences: Set<String> = [
        "Getting the model ready…",
        "The model is getting ready for this Mac — this happens once."
    ]

    var cardAndFooterContradict: Bool {
        let waitsOnTheEngine = footer.map(Self.engineWaitSentences.contains) ?? false
        return card.tone == .success && waitsOnTheEngine
    }

    var report: String {
        """
        card:   “\(card.title)” — “\(card.detail ?? "")”
        footer: “\(footer ?? "nil")”  Continue \(canAdvance ? "enabled" : "disabled")
        modelState=\(String(describing: state.modelState)) \
        isEngineReady=\(state.isEngineReady) \
        isPreparingEngine=\(state.isPreparingEngine) \
        hasEngineBeenReady=\(state.hasEngineBeenReady) \
        microphone=\(state.microphoneGranted) accessibility=\(state.accessibilityGranted) \
        preparation=\(String(describing: state.enginePreparation.phase))
        """
    }
}
