import DictationCore
import LocalASR
import XCTest

/// The first load is the one load nothing else can rescue.
///
/// Once an engine has been ready, an unloaded one is a decision with a stated
/// comeback — the next key press — and every screen is allowed to say so. An
/// engine that has never been ready has no such comeback: the key press is
/// refused with "the model is getting ready", the setup card says the model
/// rests until the next dictation, and the two sentences are about the same
/// instant. So the app is only allowed to be in that state while a preparation
/// is genuinely running. The moment preparation can end without either
/// finishing or being replaced, the first run is dead until the app is quit —
/// which is the defect this branch exists to remove, twice already.
///
/// Everything here drives a real `AppState` and reads only what the interface
/// reads. Nothing polls, retries or nudges the app: if a test passes, it passed
/// because the app finished the work by itself.
@MainActor
final class FirstLoadNeverStrandsTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws {
        harness = try AppHarness()
        harness.permissions.microphoneGranted = true
        harness.permissions.accessibilityGranted = true
    }

    override func tearDown() async throws {
        harness.tearDown()
        harness = nil
    }

    /// "Nothing happened" ends an attempt, never the preparation.
    ///
    /// A cancelled load returns `.skipped`, and `.skipped` has meant "there was
    /// nothing to do" since 0.8.2 — in one of the two places that read an
    /// outcome. The first attempt treats it as one moment's answer and tries
    /// again; the retry ladder treated it as the world's answer and stopped,
    /// leaving `isPreparingEngine` false, no task scheduled, a ready model and
    /// an engine that had never loaded. From there only ⌘Q helped, because the
    /// standing rule fires on readiness and readiness had not changed.
    ///
    /// The script is two cancellations and then an ordinary load: with the
    /// asymmetry in place the app gives up on the second one.
    func testAFirstLoadCancelledTwiceIsStillFinishedByTheAppItself() async throws {
        let recognizer = ScriptedLoadRecognizer(script: [.cancelled, .cancelled, .succeeds])
        harness.recognizer = recognizer
        try harness.installModelMarker()

        let state = harness.makeState()

        try await waitUntil("the engine finishes its first load") { state.isEngineReady }

        let attempts = await recognizer.attempts
        XCTAssertGreaterThanOrEqual(
            attempts, 3,
            "the preparation went past the cancellation that used to end it"
        )
        XCTAssertTrue(
            state.hasEngineBeenReady,
            "the first dictation has something to recognize with"
        )
        XCTAssertFalse(state.isPreparingEngine, "and the app has stopped saying it is working")
    }

    /// The app must not be left telling a person about a load it abandoned.
    ///
    /// While the ladder waits between attempts it holds the "preparing"
    /// indicator on purpose: one continuous sentence for one continuous
    /// preparation. Deleting the model revokes the ladder mid-wait — it bumps
    /// the revision the ladder checks itself against, so the ladder wakes up
    /// belonging to nobody and hands the indicator to nobody. It stayed lit
    /// forever, and with it the guard that keeps the standing rule from
    /// starting a second preparation: `prepareEngineIfIdleAndCold` will not run
    /// while the app believes a preparation is already in flight.
    func testDeletingTheModelMidRetryStopsTheAppNarratingPreparation() async throws {
        // Long enough that the delete lands in the wait between attempts, which
        // is where the ladder spends nearly all of a real retry.
        harness.engineWarmupRetryDelay = .seconds(1)
        let recognizer = ScriptedLoadRecognizer(script: [], fallback: .fails)
        harness.recognizer = recognizer
        try harness.installModelMarker()

        let state = harness.makeState()
        try await waitUntil("the first attempt fails and the ladder takes over") {
            state.isPreparingEngine
        }
        try await waitUntil("the ladder is waiting rather than attempting") {
            state.enginePreparation.phase == .loadingRecognizer
        }

        state.deleteModel()
        try await waitUntil("the files are gone") { state.modelState == .notInstalled }
        // The revoked ladder is asleep for a whole second; give it its wake-up.
        try await Task.sleep(for: .milliseconds(1_200))

        XCTAssertFalse(
            state.isPreparingEngine,
            """
            The app says it is preparing a model that has been deleted. \
            Nothing will clear this, and while it stands the standing rule \
            cannot start a preparation for the model installed next.
            """
        )
        XCTAssertEqual(
            state.enginePreparation.phase,
            .idle,
            "and the countdown it was narrating has stopped too"
        )
    }

    /// The invariant behind both tests above, stated once and watched.
    ///
    /// A ready model with an engine that has never loaded is the app's own
    /// debt, and it is the only state in which every surface lies at once: the
    /// setup card says the model rests until the next dictation, the try-out
    /// step says the model is getting ready, and a key press is refused with
    /// the second sentence while the first one is on the screen above it. All
    /// of that is true and harmless while a preparation is actually running,
    /// and all of it is a dead app the moment one is not.
    ///
    /// So the app is allowed to pass through that state and never to rest in
    /// it. Here every single load ends without an answer, forever — the
    /// harshest script there is — and the app must go on visibly working
    /// rather than fall quiet.
    func testTheAppNeverRestsOnAReadyModelWithAnEngineThatHasNeverLoaded() async throws {
        let recognizer = ScriptedLoadRecognizer(script: [], fallback: .cancelled)
        harness.recognizer = recognizer
        try harness.installModelMarker()

        let state = harness.makeState()
        // A preparation that never succeeds never stops, which is the whole
        // point — and this process outlives the test. Taking the model away is
        // the app's own way of revoking one, and it is the only thing that
        // stops this recognizer.
        defer { state.deleteModel() }
        try await waitUntil("the model is read off the disk") { state.modelState.isReady }

        var quietSamples = 0
        var worstRun = 0
        for _ in 0..<200 {
            let owesAReadyEngine =
                state.modelState.isReady && !state.isEngineReady && !state.hasEngineBeenReady
            quietSamples = owesAReadyEngine && !state.isPreparingEngine ? quietSamples + 1 : 0
            worstRun = max(worstRun, quietSamples)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertLessThan(
            worstRun, 20,
            """
            The app spent \(worstRun * 10) ms owing a ready engine with nothing \
            preparing one. Nothing will start it: readiness cannot arrive twice, \
            residency has nothing to give back, and the key press that wakes a \
            resting engine does not wake one that has never been loaded.
            """
        )
        let attempts = await recognizer.attempts
        XCTAssertGreaterThan(attempts, 2, "it kept trying, rather than merely looking busy")
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
}

/// A recognizer whose loads follow a written script.
///
/// The existing fakes either always succeed or always fail. Neither can express
/// the shape that strands a first run: an attempt that ends without an answer,
/// followed by one that would have worked.
private actor ScriptedLoadRecognizer: DictationRecognizing {
    enum Outcome {
        /// The load ends without an answer — a cancelled request, a fenced
        /// worker generation, a momentary disagreement about the model state.
        case cancelled
        /// The load fails for a reason that says nothing about the files.
        case fails
        case succeeds
    }

    private var script: [Outcome]
    private let fallback: Outcome
    private(set) var attempts = 0
    private var prepared = false
    private var observer: AsyncStream<Bool>.Continuation?

    init(script: [Outcome], fallback: Outcome = .succeeds) {
        self.script = script
        self.fallback = fallback
    }

    var isPrepared: Bool { prepared }
    var isBusy: Bool { false }

    func readinessChanges() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            observer = continuation
            continuation.yield(prepared)
        }
    }

    func prepare(modelDirectory: URL) async throws {
        attempts += 1
        switch script.isEmpty ? fallback : script.removeFirst() {
        case .cancelled: throw CancellationError()
        case .fails: throw ScriptedLoadFailure()
        case .succeeds: break
        }
    }


    func transcribe(fileURL: URL) async throws -> ASRResult {
        ASRResult(text: "", audioDuration: 1, processingDuration: 0)
    }

    func transcribe(samples: [Float]) async throws -> ASRResult {
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

/// A worker that died, a pipe that closed — anything that leaves the verified
/// files on disk untouched and only costs one generation.
private struct ScriptedLoadFailure: Error {}
