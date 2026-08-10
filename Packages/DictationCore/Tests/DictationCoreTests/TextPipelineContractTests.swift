import XCTest
@testable import DictationCore

/// Pipeline contract: stage boundaries and protected span gate.
final class TextPipelineContractTests: XCTestCase {
    private let dictionary = [
        DictionaryReplacement(spoken: "\u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}", written: "Postgres", inflects: false),
        DictionaryReplacement(spoken: "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}", written: "Sentry", inflects: false),
    ]

    // MARK: - Gate spans

    /// **Main gate of the wave.** Spans, calculated after the dictionary, reach
    /// byte-to-byte insertions.
    ///
    /// The corpus includes collision fixtures: dictionary terms inside backticks and
    /// phonetic neighbor inside the path.
    func testSpansSurviveEveryPostDictionaryStageByteForByte() {
        let corpus = [
            "\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} TextPipeline.Output \u{043F}\u{0440}\u{044F}\u{043C}\u{043E} \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}",
            "\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} `\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}` \u{0438} \u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}",
            "\u{043B}\u{0435}\u{0436}\u{0438}\u{0442} \u{0432} /Users/mik/\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}/log \u{0442}\u{043E}\u{0447}\u{043D}\u{043E}",
            "\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} `swift  test` \u{0441} --dry-run",
            "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} /etc/hosts, \u{043F}\u{043E}\u{0442}\u{043E}\u{043C} AppState.shared",
            "onTextInserted \u{0441}\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430}\u{043B}, \u{0430} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{043D}\u{0435}\u{0442}",
            "\u{0437}\u{0430}\u{0439}\u{0434}\u{0438} \u{043D}\u{0430} https://wai.computer/openramble/ now",
        ]

        let pipeline = TextPipeline(replacements: dictionary)
        for text in corpus {
            let exact = DictionaryReplacements.applyExact(dictionary, to: text)
            let afterDictionary = DictionaryReplacements.applyPhonetic(
                dictionary,
                to: exact,
                protecting: ProtectedSpanDetector.detect(in: exact)
            )
            let expected = ProtectedSpanDetector.detect(in: afterDictionary).map(\.text)

            let final = pipeline.run(text).provenance.spans.map(\.text)
            XCTAssertEqual(expected, final, "\u{0441}\u{043F}\u{0430}\u{043D}\u{044B} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{044B} \u{0434}\u{043E}\u{0436}\u{0438}\u{0442}\u{044C} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438}: \(text)")
        }
    }

    /// The spans in the origin entry actually belong to the final text.
    func testProvenanceSpansBelongToTheFinalText() {
        let run = TextPipeline(replacements: dictionary)
            .run("\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} TextPipeline.Output \u{0438} /etc/hosts")
        XCTAssertEqual(
            ProtectedSpanDetector.detect(in: run.provenance.finalText),
            run.provenance.spans
        )
    }

    // MARK: - Stage boundaries

    /// The command is separated before the dictionary - otherwise the dictionary will affect its words.
    func testCommandIsStrippedBeforeTheDictionary() {
        let terms = [DictionaryReplacement(spoken: "\u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}", written: "line", inflects: false)]
        let output = TextPipeline(replacements: terms).process("\u{043F}\u{0438}\u{0448}\u{0438} \u{0441}\u{044E}\u{0434}\u{0430} \u{0441} \u{043D}\u{043E}\u{0432}\u{043E}\u{0439} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}")
        XCTAssertFalse(output.text.contains("line"), "\u{0441}\u{043B}\u{043E}\u{0432}\u{043E} \u{043A}\u{043E}\u{043C}\u{0430}\u{043D}\u{0434}\u{044B} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}\u{0440}\u{044E} \u{043D}\u{0435} \u{0434}\u{043E}\u{0441}\u{0442}\u{0430}\u{0451}\u{0442}\u{0441}\u{044F}")
    }

    /// `afterDictionary` is removed before cosmetics: the spaces have not yet been collapsed,
    /// the first letter is still lowercase.
    func testAfterDictionaryIsTakenBeforeTypographyAndPolish() {
        let provenance = TextPipeline().run("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}   \u{043C}\u{0438}\u{0440}").provenance
        XCTAssertEqual(provenance.afterDictionary, "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}   \u{043C}\u{0438}\u{0440}")
        XCTAssertEqual(provenance.finalText, "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}")
    }

    /// Convolution of typography costs up to the polish: otherwise the non-breaking space would survive
    /// before insertion, but the polisher does not collapse it.
    func testTypographyFoldRunsBeforeThePolisher() {
        XCTAssertEqual(TextPipeline().process("\u{0434}\u{0432}\u{0430}\u{00A0}\u{00A0}\u{0441}\u{043B}\u{043E}\u{0432}\u{0430}").text, "\u{0414}\u{0432}\u{0430} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}")
    }

    /// `.newLine` must materialize after the polisher.
    ///
    /// The polisher starts with `trimmingCharacters(in: .whitespacesAndNewlines)` —
    /// the carry added earlier would simply be cut off and the command would be lost.
    func testNewLineMustRunAfterPolishOtherwiseItIsTrimmed() {
        let output = TextPipeline().process("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{0441} \u{043D}\u{043E}\u{0432}\u{043E}\u{0439} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}")
        XCTAssertTrue(output.text.hasSuffix("\n"), "\u{043F}\u{0435}\u{0440}\u{0435}\u{043D}\u{043E}\u{0441} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0434}\u{043E}\u{0436}\u{0438}\u{0442}\u{044C} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438}")
        XCTAssertNil(output.command, "\u{043A}\u{043E}\u{043C}\u{0430}\u{043D}\u{0434}\u{0430} \u{0443}\u{0436}\u{0435} \u{0432}\u{044B}\u{043F}\u{043E}\u{043B}\u{043D}\u{0435}\u{043D}\u{0430} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}\u{043E}\u{043C}")
        XCTAssertEqual(TranscriptPolisher.polish(output.text), "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", "\u{0430} \u{043F}\u{043E}\u{043B}\u{0438}\u{0448}\u{0435}\u{0440} \u{0431}\u{044B} \u{0435}\u{0451} \u{0441}\u{0440}\u{0435}\u{0437}\u{0430}\u{043B}")
    }

    // MARK: - Compatibility

    /// `process` is `run().output`, exactly one path and no second branch.
    func testProcessIsExactlyRunOutput() {
        let pipeline = TextPipeline(replacements: dictionary)
        for text in ["\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}", "\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} Foo.Bar", "", "\u{0441} \u{043D}\u{043E}\u{0432}\u{043E}\u{0439} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}"] {
            XCTAssertEqual(pipeline.process(text), pipeline.run(text).output)
        }
    }

    func testEmptyInputStaysEmpty() {
        let run = TextPipeline().run("")
        XCTAssertEqual(run.output.text, "")
        XCTAssertEqual(run.provenance.raw, "")
        XCTAssertEqual(run.provenance.spans, [])
    }
}

/// Record the origin of the last dictation.
final class PipelineProvenanceTests: XCTestCase {
    func testRawIsRecordedBeforeAnyStageTouchesIt() {
        let terms = [DictionaryReplacement(spoken: "\u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}", written: "Postgres", inflects: false)]
        let provenance = TextPipeline(replacements: terms).run("\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}").provenance
        XCTAssertEqual(provenance.raw, "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}")
        XCTAssertEqual(provenance.afterDictionary, "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres")
        XCTAssertEqual(provenance.finalText, "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres")
    }

    func testFinalTextIsExactlyWhatWillBeInserted() {
        let pipeline = TextPipeline()
        for text in ["\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}", "\u{0441} \u{043D}\u{043E}\u{0432}\u{043E}\u{0439} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}", "\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} Foo.Bar"] {
            let run = pipeline.run(text)
            XCTAssertEqual(run.provenance.finalText, run.output.text)
        }
    }

    /// Origin is built for any combination of toggle switches.
    ///
    /// This is the requirement “regardless of the settings”: branches where there is no entry,
    /// does not exist in the product.
    func testProvenanceIsProducedRegardlessOfEveryToggle() {
        for allowReturn in [true, false] {
            for phonetic in [true, false] {
                let pipeline = TextPipeline(
                    replacements: StarterDictionary.developer,
                    allowPressReturnCommand: allowReturn,
                    phoneticMatching: phonetic
                )
                let provenance = pipeline.run("\u{043D}\u{0430}\u{0434}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}").provenance
                XCTAssertEqual(provenance.raw, "\u{043D}\u{0430}\u{0434}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}")
                XCTAssertFalse(provenance.finalText.isEmpty)
            }
        }
    }

    /// “Never on disk” rests on a lack of conformity, and not on discipline.
    ///
    /// If someone adds `Codable` to "just save history", this
    /// the test will fail before the dictation text is in the file.
    func testProvenanceIsNotEncodable() {
        XCTAssertFalse(
            PipelineProvenance.self is any Encodable.Type,
            "\u{043F}\u{0440}\u{043E}\u{0438}\u{0441}\u{0445}\u{043E}\u{0436}\u{0434}\u{0435}\u{043D}\u{0438}\u{0435} \u{043D}\u{0435} \u{0441}\u{0435}\u{0440}\u{0438}\u{0430}\u{043B}\u{0438}\u{0437}\u{0443}\u{0435}\u{0442}\u{0441}\u{044F} — \u{044D}\u{0442}\u{043E} \u{0438} \u{0435}\u{0441}\u{0442}\u{044C} \u{0433}\u{0430}\u{0440}\u{0430}\u{043D}\u{0442}\u{0438}\u{044F}, \u{0447}\u{0442}\u{043E} \u{043E}\u{043D}\u{043E} \u{043D}\u{0435} \u{043F}\u{043E}\u{043F}\u{0430}\u{0434}\u{0451}\u{0442} \u{043D}\u{0430} \u{0434}\u{0438}\u{0441}\u{043A}"
        )
    }

    /// The description does not bring out a single word from the dictation.
    func testProvenanceDescriptionLeaksNoDictatedText() {
        let secret = "\u{0441}\u{043E}\u{0432}\u{0435}\u{0440}\u{0448}\u{0435}\u{043D}\u{043D}\u{043E} \u{0441}\u{0435}\u{043A}\u{0440}\u{0435}\u{0442}\u{043D}\u{0430}\u{044F} \u{0444}\u{0440}\u{0430}\u{0437}\u{0430}"
        let provenance = TextPipeline().run(secret).provenance
        let described = String(describing: provenance)

        XCTAssertFalse(described.contains("\u{0441}\u{0435}\u{043A}\u{0440}\u{0435}\u{0442}\u{043D}\u{0430}\u{044F}"))
        XCTAssertFalse(described.contains(secret))
        XCTAssertTrue(described.contains("chars"), "Character counts are safe to expose")
    }
}
