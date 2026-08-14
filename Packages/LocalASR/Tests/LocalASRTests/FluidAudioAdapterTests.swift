import CoreML
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

    /// Reference implementation of the pre-optimization lexical decision.
    /// It deliberately keeps the allocation-heavy String path so the cached
    /// Character implementation can be checked against the exact old semantics.
    private func referenceVocabularyCandidateSpans(
        words: [String],
        terms: [VocabularyBoost.Term],
        minimumSimilarity: Float
    ) -> [Range<Int>] {
        var seenForms = Set<String>()
        let forms = terms.flatMap { term -> [(form: String, canonical: String)] in
            let canonical = FluidAudioAdapter.normalizeVocabularyCandidate(term.text)
            return ([term.text] + term.aliases).compactMap { raw in
                let form = FluidAudioAdapter.normalizeVocabularyCandidate(raw)
                let key = canonical + "\u{0}" + form
                guard !form.isEmpty, seenForms.insert(key).inserted else { return nil }
                return (form, canonical)
            }
        }

        var spans: [Range<Int>] = []
        for startIndex in words.indices {
            let maximumLength = min(4, words.count - startIndex)
            for length in 1...maximumLength {
                let phrase = FluidAudioAdapter.normalizeVocabularyCandidate(
                    words[startIndex..<(startIndex + length)].joined(separator: " ")
                )
                guard !phrase.isEmpty else { continue }
                let compound = phrase.replacingOccurrences(of: " ", with: "")
                let canAffectText = forms.contains { candidate in
                    guard phrase != candidate.canonical else { return false }
                    return FluidAudioAdapter.vocabularyCandidateSimilarity(phrase, candidate.form)
                        >= minimumSimilarity
                        || FluidAudioAdapter.vocabularyCandidateSimilarity(compound, candidate.form)
                            >= minimumSimilarity
                }
                if canAffectText { spans.append(startIndex..<(startIndex + length)) }
            }
        }
        return spans
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

    /// The enum label alone used to hide FluidAudio's ANE-only default. Guard
    /// the exact Core ML contract so automatic really permits every unit.
    func testEncoderUsesPortableAutomaticPlacementByDefault() async {
        let adapter = FluidAudioAdapter()

        let placement = await adapter.placement

        XCTAssertEqual(placement, .automatic)
        XCTAssertEqual(FluidAudioAdapter.encoderComputeUnits(for: placement), .all)
        XCTAssertEqual(
            FluidAudioAdapter.encoderComputeUnits(for: .neuralEngine),
            .cpuAndNeuralEngine
        )
        XCTAssertEqual(FluidAudioAdapter.encoderComputeUnits(for: .gpu), .cpuAndGPU)
    }

    func testLongFormConcurrencyUsesTheBenchmarkedDefault() async {
        let adapter = FluidAudioAdapter()

        let concurrency = await adapter.longFormConcurrency

        XCTAssertEqual(concurrency, 4, "the portable device-matrix default must not be M4-only")
    }

    func testVocabularyInferenceUsesCandidateRegionsByDefault() async {
        let adapter = FluidAudioAdapter()

        let scheduling = await adapter.vocabularyInferenceScheduling

        XCTAssertEqual(
            scheduling,
            .candidateRegions,
            "CTC should run only after TDT proves the final rescorer can affect text"
        )
        XCTAssertFalse(
            FluidAudioAdapter.shouldStartVocabularyEvidenceInParallel(
                hasVocabulary: true,
                scheduling: .candidateRegions
            ),
            "the product path must not start speculative CTC, including short dictations"
        )
        XCTAssertTrue(
            FluidAudioAdapter.shouldStartVocabularyEvidenceInParallel(
                hasVocabulary: true,
                scheduling: .alwaysParallel
            ),
            "the benchmark/reference mode must preserve the parallel comparison lane"
        )
        XCTAssertFalse(
            FluidAudioAdapter.shouldStartVocabularyEvidenceInParallel(
                hasVocabulary: false,
                scheduling: .alwaysParallel
            )
        )
    }

    func testPhaseTimingCollectionIsOptIn() async {
        let shipping = FluidAudioAdapter()
        let benchmark = FluidAudioAdapter(collectPhaseTimings: true)
        let shippingCollects = await shipping.collectsPhaseTimings
        let benchmarkCollects = await benchmark.collectsPhaseTimings

        XCTAssertFalse(shippingCollects)
        XCTAssertTrue(benchmarkCollects)
    }

    func testVocabularyPhaseOutcomeMatrix() {
        typealias Outcome = ASRPhaseTimings.VocabularyOutcome
        let cases: [(Bool, Int, Bool, String, String, Outcome)] = [
            (false, 0, false, "a", "a", .notConfigured),
            (true, 0, false, "a", "a", .noCandidate),
            (true, 1, false, "a", "a", .candidateNoUsableEvidence),
            (true, 1, true, "a", "a", .rescoredUnmodified),
            (true, 1, true, "a", "b", .rescoredModified),
        ]

        for (hasVocabulary, candidates, didRun, primary, final, expected) in cases {
            XCTAssertEqual(
                FluidAudioAdapter.vocabularyOutcome(
                    hasVocabulary: hasVocabulary,
                    candidateCount: candidates,
                    rescoreDidRun: didRun,
                    primaryText: primary,
                    finalText: final
                ),
                expected
            )
        }
    }

    func testVocabularyOverlapUsesProbabilitySpaceMean() {
        let merged = FluidAudioAdapter.mergeVocabularyOverlap(
            existing: [0, -Float.infinity],
            incoming: [logf(0.25), -Float.infinity]
        )

        XCTAssertEqual(merged[0], logf(0.625), accuracy: 0.000_001)
        XCTAssertEqual(merged[1], -Float.infinity)
        XCTAssertEqual(
            FluidAudioAdapter.mergeVocabularyOverlap(existing: [1], incoming: []),
            [1]
        )
    }

    func testVocabularyPrefilterMatchesPinnedNormalizationAndSimilarity() {
        XCTAssertEqual(
            FluidAudioAdapter.normalizeVocabularyCandidate("  Q4, Foo.Bar\nBaz's-test  "),
            "q4 foobar baz's-test"
        )
        XCTAssertEqual(
            FluidAudioAdapter.vocabularyCandidateSimilarity("kitten", "sitting"),
            4 / 7,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            FluidAudioAdapter.vocabularyCandidateSimilarity("Postgres", "Postgres"),
            1
        )
    }

    func testBoundedVocabularySimilarityDecisionMatchesExactReference() {
        let corpus = [
            "", "a", "ab", "kitten", "sitting", "Postgres", "postgrez",
            "постгрес", "постгрез", "кубер нетес", "кубернетес", "café", "cafe\u{301}",
        ]
        let thresholds: [Float] = [0, 0.5, 0.52, 0.55, 0.65, 0.8, 1]

        for left in corpus {
            for right in corpus {
                for threshold in thresholds {
                    let expected = FluidAudioAdapter.vocabularyCandidateSimilarity(left, right) >= threshold
                    let actual = FluidAudioAdapter.vocabularyCandidateCanReachThreshold(
                        Array(left),
                        Array(right),
                        minimumSimilarity: threshold
                    )
                    XCTAssertEqual(
                        actual,
                        expected,
                        "bounded decision drifted for \(left.debugDescription), "
                            + "\(right.debugDescription), threshold \(threshold)"
                    )
                }
            }
        }

        // Deterministic generated coverage exercises different band widths,
        // length gaps, and extended grapheme clusters without making the test
        // dependent on system randomness.
        let alphabet: [Character] = ["a", "b", "é", "ж", "👩🏽‍💻", "-"]
        var state: UInt64 = 0xD1C7_A710
        func next(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int(state % UInt64(upperBound))
        }
        func generatedString() -> String {
            String((0..<next(15)).map { _ in alphabet[next(alphabet.count)] })
        }
        for _ in 0..<512 {
            let left = generatedString()
            let right = generatedString()
            for threshold in thresholds {
                let expected = FluidAudioAdapter.vocabularyCandidateSimilarity(left, right) >= threshold
                let actual = FluidAudioAdapter.vocabularyCandidateCanReachThreshold(
                    Array(left),
                    Array(right),
                    minimumSimilarity: threshold
                )
                XCTAssertEqual(actual, expected, "generated bounded decision drifted")
            }
        }
    }

    func testCachedLexicalGatePreservesTranscriptDecisionParity() {
        let terms: [VocabularyBoost.Term] = [
            .init(text: "Postgres", aliases: ["постгрес", "постгрес"]),
            .init(text: "Kubernetes", aliases: ["кубернетес"]),
            .init(text: "code review", aliases: ["код ревью"]),
        ]
        let threshold: Float = 0.65
        let gate = FluidAudioAdapter.VocabularyLexicalGate(
            terms: terms,
            minimumSimilarity: threshold
        )
        let transcripts = [
            ["обычная", "речь"],
            ["постгрез"],
            ["Postgres"],
            ["кубер", "нетес"],
            ["код", "ревъю"],
            ["code", "review"],
            ["до", "постгрез,", "после"],
            [".", "кубер", "-", "нетес"],
        ]

        XCTAssertEqual(gate.cachedFormCount, 6, "canonical/alias duplicates should be cached once")
        for words in transcripts {
            XCTAssertEqual(
                gate.candidateWordSpans(words: words),
                referenceVocabularyCandidateSpans(
                    words: words,
                    terms: terms,
                    minimumSimilarity: threshold
                ),
                "cached gate changed the previous decision for \(words)"
            )
        }
    }

    func testRareTermAliasSchedulesEvidenceButUnrelatedSpeechDoesNot() {
        let gate = FluidAudioAdapter.VocabularyLexicalGate(
            terms: [
                .init(text: "OpenTelemetry", aliases: ["опентелеметри"]),
                .init(text: "Kubernetes", aliases: ["кубернетес"]),
            ],
            minimumSimilarity: 0.65
        )

        XCTAssertTrue(
            gate.candidateWordSpans(words: ["включи", "опен", "телеметри"]).contains(1..<3),
            "a split rare-term alias must still reach the real CTC rescorer"
        )
        XCTAssertTrue(
            gate.candidateWordSpans(words: ["обычная", "русская", "речь"]).isEmpty,
            "unrelated speech must not pay for CTC"
        )
        XCTAssertTrue(
            gate.candidateWordSpans(words: ["OpenTelemetry"]).isEmpty,
            "an already-correct canonical spelling needs no acoustic rewrite"
        )
    }

    func testCachedLexicalGateIsDeterministicAcrossConcurrentReaders() async {
        let gate = FluidAudioAdapter.VocabularyLexicalGate(
            terms: VocabularyBoost.developerDefault().terms,
            minimumSimilarity: 0.65
        )
        let words = ["данные", "лежат", "в", "постгрез", "а", "кэш", "в", "редис"]
        let expected = gate.candidateWordSpans(words: words)

        let results = await withTaskGroup(of: [Range<Int>].self, returning: [[Range<Int>]].self) { group in
            for _ in 0..<128 {
                group.addTask { gate.candidateWordSpans(words: words) }
            }
            var collected: [[Range<Int>]] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.count, 128)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
    }

    func testVocabularyChunkSelectionUsesOnlyRangesThatCanAffectTheScore() {
        let sampleRate = 16_000
        XCTAssertEqual(FluidAudioAdapter.vocabularyChunkOverlapSamples, 32_000)
        XCTAssertEqual(
            FluidAudioAdapter.vocabularySelectedChunkIndices(
                audioSampleCount: 26 * sampleRate,
                candidateRegions: [10 * sampleRate..<12 * sampleRate]
            ),
            [0],
            "a candidate inside the first window must not schedule its successor"
        )
        XCTAssertEqual(
            FluidAudioAdapter.vocabularySelectedChunkIndices(
                audioSampleCount: 30 * sampleRate,
                candidateRegions: [12 * sampleRate..<(14 * sampleRate)]
            ),
            [0, 1],
            "a candidate crossing the 13-second stride boundary needs both overlapping windows"
        )
        XCTAssertEqual(
            FluidAudioAdapter.vocabularySelectedChunkIndices(
                audioSampleCount: 1_040_001,
                candidateRegions: [64 * sampleRate..<1_040_001]
            ),
            [3, 4],
            "a trailing partial chunk needs its full predecessor for the reference frame grid"
        )
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

    /// The long-form prefilter must localize a near alias instead of scheduling
    /// CTC across the whole recording.
    func testVocabularyCandidateRegionsLocalizeNearAlias() async throws {
        let directory = try ctcDirectoryOrSkip()
        let adapter = FluidAudioAdapter()
        try await adapter.loadVocabularyModels(
            from: directory,
            boost: VocabularyBoost(terms: [
                .init(text: "Postgres", aliases: ["постгрес"])
            ])
        )

        let regions = await adapter.vocabularyCandidateRegions(
            text: "обычная речь постгрез продолжается дальше",
            timings: [
                timing("▁обычная", 1.0, 1.4),
                timing("▁речь", 1.5, 1.8),
                timing("▁постгрез", 26.0, 26.8),
                timing("▁продолжается", 27.0, 27.5),
                timing("▁дальше", 27.6, 28.0),
            ],
            audioSampleCount: 30 * 16_000
        )
        XCTAssertEqual(regions.count, 1)
        XCTAssertTrue(regions[0].contains(26 * 16_000))
        XCTAssertGreaterThan(regions[0].lowerBound, 0)
        XCTAssertLessThan(regions[0].upperBound, 30 * 16_000)

        let unrelated = await adapter.vocabularyCandidateRegions(
            text: "обычная речь",
            timings: [
                timing("▁обычная", 1.0, 1.4),
                timing("▁речь", 1.5, 1.8),
            ],
            audioSampleCount: 30 * 16_000
        )
        let alreadyCorrect = await adapter.vocabularyCandidateRegions(
            text: "Postgres",
            timings: [timing("▁Postgres", 1.0, 1.8)],
            audioSampleCount: 30 * 16_000
        )
        XCTAssertTrue(unrelated.isEmpty)
        XCTAssertTrue(alreadyCorrect.isEmpty)
        await adapter.unload()
    }

    func testVocabularyCandidateRegionsIncludeEveryMatchingOccurrence() async throws {
        let directory = try ctcDirectoryOrSkip()
        let adapter = FluidAudioAdapter()
        try await adapter.loadVocabularyModels(
            from: directory,
            boost: VocabularyBoost(terms: [
                .init(text: "Postgres", aliases: ["постгрес"])
            ])
        )

        let regions = await adapter.vocabularyCandidateRegions(
            text: "постгрез обычная речь постгрез",
            timings: [
                timing("▁постгрез", 12.8, 13.2),
                timing("▁обычная", 14.0, 14.4),
                timing("▁речь", 14.5, 14.8),
                timing("▁постгрез", 25.8, 26.2),
            ],
            audioSampleCount: 30 * 16_000
        )

        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(regions[0].contains(13 * 16_000))
        XCTAssertTrue(regions[1].contains(26 * 16_000))
        await adapter.unload()
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
