import DictationCore
import LocalASR
import XCTest

/// Hebrew is an optional second model.
///
/// It is offered only on a Mac with a Hebrew keyboard, and a take is
/// recognized with it while that keyboard is the one in use. The main model
/// stays required and untouched throughout.
@MainActor
final class HebrewModelAppTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    // MARK: Who is offered it

    func testAMacWithoutAHebrewKeyboardIsNeverShownHebrew() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()

        await state.refreshModelState()

        XCTAssertFalse(state.offersHebrewModel)
        XCTAssertEqual(state.hebrewModelState, .notInstalled)
    }

    func testAMacWithAHebrewKeyboardIsOfferedTheDownload() async throws {
        try harness.installModelMarker()
        harness.keyboardLanguages = KeyboardLanguages(current: "en", enabled: ["en", "he"])
        let state = harness.makeState()

        await state.refreshModelState()

        XCTAssertTrue(state.offersHebrewModel)
        XCTAssertEqual(state.hebrewModelState, .notInstalled, "offered, not imposed")
        XCTAssertEqual(state.hebrewModelMegabytes, 740, "counted as the progress under the button counts")
        XCTAssertTrue(state.modelState.isReady, "the main model is not part of the offer")
    }

    func testAddingAHebrewKeyboardShowsTheOfferWithoutARelaunch() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        XCTAssertFalse(state.offersHebrewModel)

        harness.keyboardLanguages.enabled = ["en", "he"]
        harness.keyboardNotifications.post(name: KeyboardLanguages.changes[1], object: nil)
        for _ in 0..<500 where !state.offersHebrewModel {
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertTrue(state.offersHebrewModel)
    }

    // MARK: Which model a take uses

    func testWhileTheKeyboardIsHebrewTheEngineLoadsTheHebrewModel() async throws {
        let (state, engine) = try await bothInstalled(keyboard: "he")

        XCTAssertTrue(state.isEngineReady)
        XCTAssertTrue(try XCTUnwrap(engine.loadedDirectories.last).path.contains("parakeet-tdt-0.6b-v3-he"))
        XCTAssertTrue(state.modelState.isReady, "the main card still describes the main model")
    }

    func testOnAnyOtherKeyboardTheMainModelIsLoaded() async throws {
        let (_, engine) = try await bothInstalled(keyboard: "en")

        XCTAssertTrue(engine.loadedDirectories.allSatisfy { $0.path.contains("parakeet-ultra") }, "\(engine.loadedDirectories)")
    }

    func testSwitchingKeyboardsSwitchesModelsBothWays() async throws {
        let (state, engine) = try await bothInstalled(keyboard: "en")

        harness.switchKeyboard(to: "he")
        try await waitForLoad(of: "parakeet-tdt-0.6b-v3-he", engine, state)

        harness.switchKeyboard(to: "ru")
        try await waitForLoad(of: "parakeet-ultra", engine, state)
    }

    func testAHebrewKeyboardWithoutTheHebrewModelKeepsTheMainModel() async throws {
        try harness.installModelMarker()
        harness.keyboardLanguages = KeyboardLanguages(current: "he", enabled: ["en", "he"])
        let engine = DirectoryRecordingEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()

        await state.refreshModelState()
        try await waitUntilReady(state)

        XCTAssertTrue(engine.loadedDirectories.allSatisfy { $0.path.contains("parakeet-ultra") })
    }

    func testHebrewNeverStandsInForAMissingMainModel() async throws {
        try harness.installHebrewModelMarker()
        harness.keyboardLanguages = KeyboardLanguages(current: "he", enabled: ["en", "he"])
        let engine = DirectoryRecordingEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()

        await state.refreshModelState()
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(state.modelState, .notInstalled, "the app is not set up without its model")
        XCTAssertTrue(state.hebrewModelState.isReady)
        XCTAssertEqual(engine.loadedDirectories, [])
    }

    /// The model under a take never changes: the switch waits for the take.
    func testASwitchOfKeyboardsWaitsForATakeToEnd() async throws {
        let (state, engine) = try await bothInstalled(keyboard: "en")

        harness.monitor.onPress?()
        try await waitUntil { state.dictationState != .idle }
        harness.switchKeyboard(to: "he")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(loadedHebrew(engine), "the take keeps the model it started with")

        harness.monitor.onRelease?()
        try await waitUntil { state.dictationState == .idle }
        try await waitForLoad(of: "parakeet-tdt-0.6b-v3-he", engine, state)
    }

    /// Someone who types notes in Hebrew during a call switches keyboards.
    /// The call must not change models halfway through.
    func testASwitchOfKeyboardsWaitsForARecordingToEnd() async throws {
        let (state, engine) = try await bothInstalled(keyboard: "en")

        state.startRecording()
        if state.isSystemAudioIntroPresented { state.confirmSystemAudioIntro(includeSystemAudio: false) }
        try await waitUntil { state.meetingState == .recording }
        harness.switchKeyboard(to: "he")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(loadedHebrew(engine), "the recording keeps the model it started with")

        state.stopRecording()
        try await waitUntil { state.meetingState == .idle }
        try await waitForLoad(of: "parakeet-tdt-0.6b-v3-he", engine, state)
    }

    // MARK: Downloading and removing

    func testTheDownloadFetchesTheHebrewFileAndLeavesTheMainModelAlone() async throws {
        try harness.installModelMarker()
        harness.keyboardLanguages = KeyboardLanguages(current: "en", enabled: ["en", "he"])
        let state = harness.makeState()
        await state.refreshModelState()

        state.installHebrewModel()
        for _ in 0..<500 where !harness.downloader.hasStarted {
            try await Task.sleep(for: .milliseconds(2))
        }

        let url = try XCTUnwrap(harness.downloader.requestedURLs.first)
        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertTrue(url.path.hasSuffix("/parakeet-tdt-0.6b-v3-he-Q8_0.gguf"), url.path)
        guard case .downloading = state.hebrewModelState else {
            return XCTFail("the Hebrew card shows the download: \(state.hebrewModelState)")
        }
        XCTAssertTrue(state.modelState.isReady, "dictation is untouched while Hebrew downloads")

        harness.downloader.release(throwing: .cancelled)
        for _ in 0..<500 {
            if case .downloading = state.hebrewModelState { try await Task.sleep(for: .milliseconds(2)) } else { break }
        }
        XCTAssertFalse(state.hebrewModelState.isReady)
        XCTAssertTrue(state.modelState.isReady)
        XCTAssertTrue(state.offersHebrewModel, "the offer is still there to try again")
    }

    func testRemovingHebrewRemovesOnlyHebrewAndGoesBackToTheMainModel() async throws {
        let (state, engine) = try await bothInstalled(keyboard: "he")
        let folder = try harness.hebrewModelDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        state.deleteHebrewModel()
        for _ in 0..<1000 where state.hebrewModelState != .notInstalled {
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(state.hebrewModelState, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(state.modelState.isReady)
        try await waitForLoad(of: "parakeet-ultra", engine, state)
        XCTAssertTrue(state.offersHebrewModel, "the keyboard is still there, so is the offer")
    }

    // MARK: What the card says

    func testTheCardNeverSaysDictationDependsOnHebrew() {
        let offer = ModelStatus.hebrew(state: .notInstalled, place: .settings, downloadMegabytes: 740)
        XCTAssertEqual(offer.title, "Hebrew")
        XCTAssertEqual(offer.actions, [.install])
        XCTAssertEqual(offer.title(for: .install), "Download — 740 MB")
        XCTAssertTrue(offer.isAddition)

        let installed = ModelState.ready(directory: URL(fileURLWithPath: "/models/he", isDirectory: true))
        let ready = ModelStatus.hebrew(state: installed, place: .settings, downloadMegabytes: 740)
        XCTAssertEqual(
            ModelStatus.hebrew(state: installed, place: .onboarding, downloadMegabytes: 740).actions, [],
            "removing a model is a Settings matter"
        )
        XCTAssertEqual(ready.detail, "Used while your keyboard is set to Hebrew.")
        XCTAssertEqual(ready.actions, [.delete])
        XCTAssertEqual(ready.title(for: .delete), "Remove")
        XCTAssertFalse(ready.hint(for: .delete).contains("stops working"))

        let failed = ModelStatus.hebrew(state: .failed(.download("offline")), place: .settings, downloadMegabytes: 740)
        XCTAssertEqual(failed.actions, [.retry])
        XCTAssertEqual(failed.detail, "Dictation in other languages is not affected.")
    }

    // MARK: Helpers

    private func bothInstalled(keyboard: String) async throws -> (AppState, DirectoryRecordingEngine) {
        try harness.installModelMarker()
        try harness.installHebrewModelMarker()
        harness.keyboardLanguages = KeyboardLanguages(current: keyboard, enabled: ["en", "ru", "he"])
        let engine = DirectoryRecordingEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()
        await state.refreshModelState()
        try await waitUntilReady(state)
        return (state, engine)
    }

    private func loadedHebrew(_ engine: DirectoryRecordingEngine) -> Bool {
        engine.loadedDirectories.contains { $0.path.contains("parakeet-tdt-0.6b-v3-he") }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1500 where !condition() {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func waitUntilReady(_ state: AppState) async throws {
        for _ in 0..<1000 where !state.isEngineReady {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(state.isEngineReady)
    }

    private func waitForLoad(
        of name: String,
        _ engine: DirectoryRecordingEngine,
        _ state: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1000 {
            if state.isEngineReady, engine.loadedDirectories.last?.path.contains(name) == true { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("expected \(name) to be loaded, got \(engine.loadedDirectories.map(\.lastPathComponent))", file: file, line: line)
    }
}
