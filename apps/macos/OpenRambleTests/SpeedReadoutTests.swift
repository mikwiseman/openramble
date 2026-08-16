import XCTest

/// Engine preparation state: honest seconds instead of fictitious progress.
final class EnginePreparationStateTests: XCTestCase {
    /// There is no ANE compilation progress signal. Painted stripe
    /// would promise a period that no one knows.
    func testScenario007() {
        for phase in [
            EnginePreparationState.Phase.idle,
            .loadingRecognizer,
            .loadingVocabulary,
            .ready,
        ] {
            let state = EnginePreparationState.make(phase: phase, elapsed: 7)
            XCTAssertFalse(state.title.contains("%"), "\(phase)")
            XCTAssertFalse(state.detail?.contains("%") ?? false, "\(phase)")
            XCTAssertFalse(state.title.isEmpty, "\(phase)")
        }
    }

    func testScenario008() {
        XCTAssertEqual(
            EnginePreparationState.make(phase: .loadingRecognizer, elapsed: 14).title,
            "Loading the recognizer… 14 s"
        )
        XCTAssertEqual(
            EnginePreparationState.make(phase: .loadingVocabulary, elapsed: 3).title,
            "Loading the term booster… 3 s"
        )
    }

    func testScenario009() {
        let ready = EnginePreparationState.make(phase: .ready, elapsed: 0)
        XCTAssertEqual(ready.title, "Ready to dictate")
        XCTAssertNil(ready.detail)
    }

    /// Engine failure is not included here: it already has an owner -
    /// `ModelStatus.repairRequired`. The second type would disagree with the first about the same thing.
    func testScenario010() {
        let phases: [EnginePreparationState.Phase] = [.idle, .loadingRecognizer, .loadingVocabulary, .ready]
        for phase in phases {
            let state = EnginePreparationState.make(phase: phase, elapsed: 1)
            XCTAssertFalse(state.title.lowercased().contains("fail"), "\(phase)")
            XCTAssertFalse(state.title.lowercased().contains("error"), "\(phase)")
        }
    }
}

/// The engine preparation countdown reaches the person.
@MainActor
final class EnginePreparationWiringTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    /// At rest, the timer does not tick: the application does not have the right to spin anything
    /// in the background simply because it is running.
    func testScenario011() {
        let state = harness.makeState()
        XCTAssertFalse(state.isCountingEnginePreparation)
        XCTAssertEqual(state.enginePreparation.phase, .idle)
    }

    /// Living seconds reach the line that a person sees - otherwise
    /// wait is read as hanging.
    func testScenario012() {
        let status = ModelStatus.make(
            state: .ready(directory: URL(fileURLWithPath: "/tmp")),
            preparation: .make(phase: .loadingRecognizer, elapsed: 9),
            place: .settings,
            isEngineReady: false,
            isPreparingEngine: true
        )
        XCTAssertEqual(status.progressLabel, "Step 1 of 3 · Loading the recognizer… 9 s")
    }

    /// The second model is a separate phase: merging them into one line means
    /// show “a little more” when new work has started.
    func testScenario013() {
        let status = ModelStatus.make(
            state: .ready(directory: URL(fileURLWithPath: "/tmp")),
            preparation: .make(phase: .loadingVocabulary, elapsed: 2),
            place: .settings,
            isEngineReady: false,
            isPreparingEngine: true
        )
        XCTAssertEqual(status.progressLabel, "Step 2 of 3 · Loading the term booster… 2 s")
        XCTAssertEqual(status.progress ?? -1, 1.0 / 3.0, accuracy: 0.001)
    }

    /// The preparation is over - there is no line at all.
    func testScenario014() {
        let status = ModelStatus.make(
            state: .ready(directory: URL(fileURLWithPath: "/tmp")),
            preparation: .make(phase: .ready, elapsed: 0),
            place: .settings
        )
        XCTAssertNil(status.detail)
    }
}
