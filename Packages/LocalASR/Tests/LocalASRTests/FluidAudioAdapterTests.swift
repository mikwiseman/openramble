import DictationCore
import FluidAudio
import XCTest
@testable import LocalASR

/// Checks for gluing tokens into words.
///
/// A model is not needed here: `words(from:)` is a pure function, namely it decides
/// what word-by-word timings look like, on which all post-processing is then based.
final class FluidAudioAdapterTests: XCTestCase {
    private func timing(_ token: String, _ start: Double, _ end: Double, confidence: Float = 1) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: confidence)
    }

    func testEmptyTimingsProduceNoWords() {
        XCTAssertTrue(FluidAudioAdapter.words(from: nil).isEmpty)
        XCTAssertTrue(FluidAudioAdapter.words(from: []).isEmpty)
    }

    func testJoinsSubwordTokensIntoSingleWord() {
        // Parakeet cuts words into subwords: the beginning of the word is marked " ",
        // continuation goes without a label.
        let words = FluidAudioAdapter.words(from: [
            timing("▁\u{043F}\u{0440}\u{0438}", 0.0, 0.2),
            timing("\u{0432}\u{0435}\u{0442}", 0.2, 0.4),
            timing("▁\u{043C}\u{0438}\u{0440}", 0.5, 0.7),
        ])

        XCTAssertEqual(words.map(\.text), ["\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", "\u{043C}\u{0438}\u{0440}"])
        XCTAssertEqual(words[0].start, 0.0)
        // The end of a word is the end of its last token, not the first.
        XCTAssertEqual(words[0].end, 0.4)
        XCTAssertEqual(words[1].start, 0.5)
    }

    func testHandlesLeadingSpaceStyleTokens() {
        let words = FluidAudioAdapter.words(from: [
            timing(" hello", 0.0, 0.3),
            timing(" world", 0.4, 0.8),
        ])

        XCTAssertEqual(words.map(\.text), ["hello", "world"])
    }

    func testWordConfidenceTakesTheWeakestToken() {
        // A word is only as reliable as its worst piece -
        // otherwise confidence is overestimated where the model was in doubt.
        let words = FluidAudioAdapter.words(from: [
            timing("▁\u{0434}\u{0438}\u{043A}", 0.0, 0.2, confidence: 0.95),
            timing("\u{0442}\u{043E}\u{0432}", 0.2, 0.3, confidence: 0.40),
            timing("\u{043A}\u{0430}", 0.3, 0.4, confidence: 0.90),
        ])

        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].text, "\u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430}")
        XCTAssertEqual(try XCTUnwrap(words[0].confidence), 0.40, accuracy: 0.001)
    }

    func testSkipsEmptyTokens() {
        let words = FluidAudioAdapter.words(from: [
            timing("▁", 0.0, 0.1),
            timing("▁\u{0442}\u{0435}\u{0441}\u{0442}", 0.1, 0.3),
            timing("  ", 0.3, 0.4),
        ])

        XCTAssertEqual(words.map(\.text), ["\u{0442}\u{0435}\u{0441}\u{0442}"])
    }

    func testTimingsStayMonotonic() {
        let words = FluidAudioAdapter.words(from: [
            timing("▁\u{0440}\u{0430}\u{0437}", 0.0, 0.3),
            timing("▁\u{0434}\u{0432}\u{0430}", 0.35, 0.6),
            timing("▁\u{0442}\u{0440}\u{0438}", 0.7, 1.0),
        ])

        for index in 1..<words.count {
            XCTAssertLessThanOrEqual(
                words[index - 1].end,
                words[index].start,
                "\u{0421}\u{043B}\u{043E}\u{0432}\u{0430} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{043D}\u{0430}\u{043A}\u{043B}\u{0430}\u{0434}\u{044B}\u{0432}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0434}\u{0440}\u{0443}\u{0433} \u{043D}\u{0430} \u{0434}\u{0440}\u{0443}\u{0433}\u{0430}"
            )
        }
    }

    /// The value of the flag is not a detail of the settings, but the measurement output: with enabled
    /// mel-context on records with language switching disappeared
    /// offers, without warning and without error. The test keeps the choice in place,
    /// because return the default value of the library - one line, and
    /// You can notice the loss only by the missing text.
    func testMelChunkContextIsOffByDefault() async {
        let adapter = FluidAudioAdapter()

        let enabled = await adapter.usesMelChunkContext

        XCTAssertFalse(enabled, "\u{0412}\u{043A}\u{043B}\u{044E}\u{0447}\u{0451}\u{043D}\u{043D}\u{044B}\u{0439} mel-\u{043A}\u{043E}\u{043D}\u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043C}\u{043E}\u{043B}\u{0447}\u{0430} \u{0441}\u{044A}\u{0435}\u{0434}\u{0430}\u{0435}\u{0442} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{0430} \u{0441}\u{0442}\u{044B}\u{043A}\u{0435} \u{043E}\u{043A}\u{043E}\u{043D}")
    }

    /// The encoder runs on the GPU by default, and this is a measured
    /// decision, not taste: the ANE path pays ~16 s of program
    /// specialization every time macOS purges its e5rt cache — which the
    /// field machine does regularly — while the GPU path worst-cases at
    /// ~7 s and typically loads in 0.3 s, with an identical transcript.
    /// Reverting to `.neuralEngine` is one line; the person would only
    /// notice as the return of "Transcribing…" that hangs for ages.
    func testEncoderRunsOnTheGpuByDefault() async {
        let adapter = FluidAudioAdapter()

        let placement = await adapter.placement

        XCTAssertEqual(placement, .gpu, "the predictable engine beats the occasionally-fastest one")
    }

    func testLongFormConcurrencyUsesTheBenchmarkedDefault() async {
        let adapter = FluidAudioAdapter()

        let concurrency = await adapter.longFormConcurrency

        XCTAssertEqual(concurrency, 6, "six windows won the measured M4 latency sweep")
    }

    /// The ceiling of tokens on the window is also a measurement output, not a taste setting.
    /// Library 150 in dense speech silently interrupt the analysis of the window: at the phrase
    /// the middle disappears, there is no error. The test guards the selected value according to
    /// same reason as the mel context: return the default - one line, and
    /// You can notice the loss only by the missing text.
    func testChunkTokenCeilingIsRaisedAboveTheLibraryDefault() async {
        let adapter = FluidAudioAdapter()

        let ceiling = await adapter.chunkTokenCeiling

        XCTAssertGreaterThan(
            ceiling,
            150,
            "\u{041F}\u{043E}\u{0442}\u{043E}\u{043B}\u{043E}\u{043A} 150 \u{043C}\u{043E}\u{043B}\u{0447}\u{0430} \u{0441}\u{044A}\u{0435}\u{0434}\u{0430}\u{0435}\u{0442} \u{0440}\u{0435}\u{0447}\u{044C} \u{043D}\u{0430} \u{043F}\u{043B}\u{043E}\u{0442}\u{043D}\u{043E}\u{0439} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0435}"
        )
        // Above the theoretical maximum of the window, loop protection stops
        // exist: 187 frames × 10 tokens per frame = 1870.
        XCTAssertLessThan(ceiling, 1_870, "\u{041F}\u{043E}\u{0442}\u{043E}\u{043B}\u{043E}\u{043A} \u{0432}\u{044B}\u{0448}\u{0435} \u{043C}\u{0430}\u{043A}\u{0441}\u{0438}\u{043C}\u{0443}\u{043C}\u{0430} \u{043E}\u{043A}\u{043D}\u{0430} — \u{044D}\u{0442}\u{043E} \u{043E}\u{0442}\u{0441}\u{0443}\u{0442}\u{0441}\u{0442}\u{0432}\u{0438}\u{0435} \u{0437}\u{0430}\u{0449}\u{0438}\u{0442}\u{044B}")
    }

    func testCancelledVocabularyRebuildStopsBeforeMutatingTheAdapter() async throws {
        let adapter = FluidAudioAdapter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await adapter.loadVocabularyModels(
                from: URL(fileURLWithPath: "/tmp/cancelled-vocabulary-rebuild"),
                boost: VocabularyBoost(terms: [])
            )
        }

        do {
            try await task.value
            XCTFail("a cancelled rebuild must not reach vocabulary assignment")
        } catch is CancellationError {
            // Expected: the checkpoint precedes even the empty-list mutation.
        }
        let count = await adapter.boostedTermCount
        XCTAssertEqual(count, 0)
    }

    /// Folder of the installed prompt or an intelligible omission.
    private func ctcDirectoryOrSkip() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["WAI_CTC_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let manifest = try ModelManifest.bundledVocabulary()
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = try ModelInstallLayout(manifest: manifest, root: root).engineDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip(
                "The vocabulary model is not installed at \(directory.path). "
                    + "Install it with asr-bench install-vocab or set WAI_CTC_DIR."
            )
        }
        return directory
    }

    /// Editing the dictionary must reach the acoustics without restarting.
    ///
    /// Previously, reloading went to `guard spotter == nil` and silently
    /// did nothing: text replacements picked up the new term immediately, and
    /// the acoustic set remained the same as it was at the start of the application.
    /// The dictionary behaved differently in its two halves, and see this
    /// it was impossible outside.
    func testScenario001() async throws {
        let directory = try ctcDirectoryOrSkip()
        let adapter = FluidAudioAdapter()

        try await adapter.loadVocabularyModels(from: directory, boost: .developerDefault())
        let initial = await adapter.boostedTermCount
        XCTAssertGreaterThan(initial, 2, "\u{0421}\u{0442}\u{0430}\u{0440}\u{0442}\u{043E}\u{0432}\u{044B}\u{0439} \u{043D}\u{0430}\u{0431}\u{043E}\u{0440} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{0431}\u{044B}\u{0442}\u{044C} \u{043D}\u{0435}\u{043F}\u{0443}\u{0441}\u{0442}\u{044B}\u{043C}")

        let narrowed = VocabularyBoost(terms: [
            .init(text: "Postgres", aliases: ["\u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0435}\u{0441}"]),
            .init(text: "Kubernetes", aliases: ["\u{043A}\u{0443}\u{0431}\u{0435}\u{0440}\u{043D}\u{0435}\u{0442}\u{0435}\u{0441}"]),
        ])
        try await adapter.loadVocabularyModels(from: directory, boost: narrowed)

        let rebuilt = await adapter.boostedTermCount
        XCTAssertEqual(rebuilt, 2, "\u{041D}\u{043E}\u{0432}\u{044B}\u{0439} \u{0441}\u{043F}\u{0438}\u{0441}\u{043E}\u{043A} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0437}\u{0430}\u{043C}\u{0435}\u{043D}\u{0438}\u{0442}\u{044C} \u{043F}\u{0440}\u{0435}\u{0436}\u{043D}\u{0438}\u{0439}, \u{0430} \u{043D}\u{0435} \u{0431}\u{044B}\u{0442}\u{044C} \u{043F}\u{0440}\u{043E}\u{0438}\u{0433}\u{043D}\u{043E}\u{0440}\u{0438}\u{0440}\u{043E}\u{0432}\u{0430}\u{043D}\u{043D}\u{044B}\u{043C}")

        await adapter.unload()
    }

    /// An erased dictionary is also an edit: the tooltip is removed, not left
    /// hang with the same terms until restarted.
    func testScenario002() async throws {
        let directory = try ctcDirectoryOrSkip()
        let adapter = FluidAudioAdapter()

        try await adapter.loadVocabularyModels(from: directory, boost: .developerDefault())
        let loaded = await adapter.boostedTermCount
        XCTAssertGreaterThan(loaded, 0)

        try await adapter.loadVocabularyModels(from: directory, boost: VocabularyBoost(terms: []))

        let afterClearing = await adapter.boostedTermCount
        XCTAssertEqual(afterClearing, 0, "\u{041F}\u{0443}\u{0441}\u{0442}\u{043E}\u{0439} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}\u{0440}\u{044C} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0432}\u{044B}\u{043A}\u{043B}\u{044E}\u{0447}\u{0438}\u{0442}\u{044C} \u{0430}\u{043A}\u{0443}\u{0441}\u{0442}\u{0438}\u{0447}\u{0435}\u{0441}\u{043A}\u{0438}\u{0435} \u{043F}\u{043E}\u{0434}\u{0441}\u{043A}\u{0430}\u{0437}\u{043A}\u{0438}")

        await adapter.unload()
    }

    /// A problem with the dictionary has no right to look like damage to the model.
    ///
    /// The difference is visible to the user's eyes: `modelsUnavailable` means
    /// “download 483 MB”, and the application honestly offers this. The term is like this
    /// pumping does not help anything - it will remain the same. Therefore, problems with
    /// the list of terms goes by their type.
    func testScenario003() async throws {
        let directory = try ctcDirectoryOrSkip()
        let adapter = FluidAudioAdapter()
        // Terms that are not in any subdictionary: emoji, hieroglyphs,
        // cuneiform. Exactly those at which tokenization could give up.
        let exotic = VocabularyBoost(terms: [
            .init(text: "😀🎉"),
            .init(text: "漢字テスト"),
            .init(text: "𐎠𐎡𐎢"),
        ])

        do {
            try await adapter.loadVocabularyModels(from: directory, boost: exotic)
        } catch let error as VocabularyBoostError {
            guard case .termNotTokenizable = error else {
                return XCTFail("Unexpected dictionary error: \(error)")
            }
        } catch let error as ASREngineError {
            XCTFail("The term list was mistaken for corrupt model data: \(error)")
        }

        await adapter.unload()
    }

    /// Folder of the installed main model or an intelligible omission.
    private func modelDirectoryOrSkip() throws -> URL {
        let manifest = try ModelManifest.bundled()
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = try ModelInstallLayout(manifest: manifest, root: root).engineDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("The model is not installed at \(directory.path). Install it with asr-bench install.")
        }
        return directory
    }

    /// A stop that gets inside the preview launch must stop it.
    ///
    /// The actor does not hold the queue: while the launch was waiting for the weights to load, `stopPreview`
    /// went inside, saw an empty `previewManager` and left with nothing, and the launch
    /// then brought the matter to an end. The preview remained working forever,
    /// the next dictation did not receive it at all - and the person saw in front of him
    /// text of the **last** session. A short dictation where `.listening` alternates
    /// on `.transcribing` almost immediately, falls into this gap regularly.
    func testScenario004() async throws {
        let directory = try modelDirectoryOrSkip()
        let adapter = FluidAudioAdapter()
        try await adapter.loadModels(from: directory)

        // Wait until the request has actually entered the actor. A stop before that point
        // would precede the start rather than race with it.
        let starting = Task { try? await adapter.startPreview { _, _ in } }
        for _ in 0..<1_000 {
            let isStarting = await adapter.isPreviewStarting
            let isRunning = await adapter.isPreviewRunning
            if isStarting || isRunning { break }
            await Task.yield()
        }
        await adapter.stopPreview()
        _ = await starting.value

        let leftRunning = await adapter.isPreviewRunning
        XCTAssertFalse(
            leftRunning,
            "Preview remained active after stop; the next dictation could show stale text."
        )

        // And the next launch must take place, and not stumble upon a ghost.
        try await adapter.startPreview { _, _ in }
        let restarted = await adapter.isPreviewRunning
        XCTAssertTrue(restarted, "Preview must be able to restart after being stopped.")

        await adapter.stopPreview()
        await adapter.unload()
    }

    func testAdapterOwnsOfflineModeBeforeLoading() {
        ModelHub.offlineMode = false

        FluidAudioAdapter.enforceOfflineMode()

        XCTAssertTrue(ModelHub.offlineMode)
    }

    /// A folder without CTC bundles is a loading error, not a silent “hint”
    /// don't work." There is no network here: the failure occurs while checking files.
    func testScenario005() async throws {
        let adapter = FluidAudioAdapter()
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ctc-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        do {
            try await adapter.loadVocabularyModels(
                from: empty,
                boost: VocabularyBoost(terms: [.init(text: "deploy")])
            )
            XCTFail("\u{041F}\u{0443}\u{0441}\u{0442}\u{0430}\u{044F} \u{043F}\u{0430}\u{043F}\u{043A}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{0434}\u{0430}\u{0442}\u{044C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0443} \u{0437}\u{0430}\u{0433}\u{0440}\u{0443}\u{0437}\u{043A}\u{0438} \u{043F}\u{043E}\u{0434}\u{0441}\u{043A}\u{0430}\u{0437}\u{0447}\u{0438}\u{043A}\u{0430}")
        } catch let error as ASREngineError {
            guard case .modelsUnavailable = error else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} modelsUnavailable, \u{043F}\u{0440}\u{0438}\u{0448}\u{043B}\u{043E}: \(error)")
            }
        }
    }

    /// An empty list of terms is a conscious “hints are turned off”, not
    /// a reason to load CTC models into memory.
    func testScenario006() async throws {
        let adapter = FluidAudioAdapter()
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")

        // The folder does not exist, but with an empty list of terms the adapter should not
        // even try to read it.
        try await adapter.loadVocabularyModels(from: missing, boost: VocabularyBoost(terms: []))
    }

    /// Unknown language code is a caller error, and it is immediately visible,
    /// before loading models: it does not have the right to silently turn into “auto”.
    func testScenario007() async {
        let adapter = FluidAudioAdapter()

        do {
            _ = try await adapter.transcribe(samples: [0.1, 0.2], languageHint: "xx")
            XCTFail("\u{041D}\u{0435}\u{0438}\u{0437}\u{0432}\u{0435}\u{0441}\u{0442}\u{043D}\u{044B}\u{0439} \u{043A}\u{043E}\u{0434} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0434}\u{0430}\u{0442}\u{044C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0443}")
        } catch let error as ASREngineError {
            guard case let .inferenceFailed(detail) = error else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} inferenceFailed, \u{043F}\u{0440}\u{0438}\u{0448}\u{043B}\u{043E}: \(error)")
            }
            XCTAssertTrue(detail.contains("xx"))
        } catch {
            XCTFail("\u{041D}\u{0435}\u{043E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043D}\u{043D}\u{0430}\u{044F} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430}: \(error)")
        }
    }

    /// The list of hints is a source for selecting a language in the interface.
    func testScenario008() {
        let hints = FluidAudioAdapter.supportedLanguageHints

        XCTAssertTrue(hints.contains("ru"))
        XCTAssertTrue(hints.contains("en"))
        XCTAssertEqual(hints.count, Set(hints).count, "\u{0414}\u{0443}\u{0431}\u{043B}\u{0438}\u{043A}\u{0430}\u{0442}\u{044B} \u{0441}\u{043B}\u{043E}\u{043C}\u{0430}\u{043B}\u{0438} \u{0431}\u{044B} Picker")
    }

    func testMixedRussianEnglishKeepsLatinIntact() {
        // Main product scenario: English terms inside Russian speech
        // should not be stuck together with neighboring words.
        let words = FluidAudioAdapter.words(from: [
            timing("▁\u{0437}\u{0430}\u{043A}\u{0438}\u{043D}\u{0443}\u{043B}", 0.0, 0.4),
            timing("▁pull", 0.5, 0.7),
            timing("▁request", 0.75, 1.1),
        ])

        XCTAssertEqual(words.map(\.text), ["\u{0437}\u{0430}\u{043A}\u{0438}\u{043D}\u{0443}\u{043B}", "pull", "request"])
    }
}
