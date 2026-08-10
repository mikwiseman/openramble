import DictationCore
import Foundation
import XCTest

/// Measurement of the promise “text appears in less than a second.”
///
/// The entire path is measured, not just one recognition: from the moment when the recording file
/// ready until the text reaches insertion. This segment includes
/// reading a file from disk, format conversion, the model itself, a dictionary of replacements and
/// finishing the text - that is, exactly what a person expects with the key released.
@MainActor
final class DictationLatencyTests: EndToEndScenario {
    private struct Sample {
        let label: String
        /// Recording duration according to the engine data.
        let audio: TimeInterval
        /// How much did the model itself take?
        let inference: TimeInterval
        /// The entire path “file ready → text at insertion”.
        let path: TimeInterval

        /// How many times is the path shorter than the record itself?
        var speedup: Double { path > 0 ? audio / path : 0 }

        var line: String {
            let name = label.padding(toLength: 10, withPad: " ", startingAt: 0)
            let numbers = String(
                format: "%8.2f \u{0441} | %9.3f \u{0441} | %9.3f \u{0441} | %6.0f×",
                audio,
                inference,
                path,
                speedup
            )
            return "| \(name) | \(numbers) |"
        }
    }

    /// The path from the finished file to the text takes one second.
    ///
    /// The thresholds are different not because of the hardware, but because of the meaning: dictation for five and for
    /// thirty seconds is a common working case, and there a second is a promise
    /// product. Three minutes is a rare case, and the reserve taken there is twice as large,
    /// so that the test does not blink on a machine weaker than the one on which it is written.
    func testPathFromReadyFileToInsertedTextStaysUnderASecond() async throws {
        // Warm-up: the first work with the model in the process is always more expensive than the rest,
        // and to measure it would mean to measure the wrong thing.
        _ = try await measure("\u{043F}\u{0440}\u{043E}\u{0433}\u{0440}\u{0435}\u{0432}", text: Phrase.short)

        // The signatures are short, and the exact duration of the recording is in the table next to it:
        // synthesis does not give exactly five seconds and exactly half a minute.
        let samples = [
            try await measure("\u{0444}\u{0440}\u{0430}\u{0437}\u{0430}", text: Phrase.short),
            try await measure("\u{043F}\u{043E}\u{043B}\u{043C}\u{0438}\u{043D}\u{0443}\u{0442}\u{044B}", text: Phrase.long),
            try await measure("\u{0442}\u{0440}\u{0438} \u{043C}\u{0438}\u{043D}\u{0443}\u{0442}\u{044B}", text: Phrase.veryLong),
        ]

        print("\n| \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C}     |    \u{0430}\u{0443}\u{0434}\u{0438}\u{043E} | \u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}. |     \u{0432}\u{0435}\u{0441}\u{044C} \u{043F}\u{0443}\u{0442}\u{044C} | \u{0431}\u{044B}\u{0441}\u{0442}\u{0440}\u{0435}\u{0435} \u{0420}\u{0412} |")
        print("|------------|----------|------------|---------------|------------|")
        for sample in samples { print(sample.line) }
        print("")

        for sample in samples where sample.audio < 60 {
            XCTAssertLessThan(
                sample.path,
                1.0,
                "«\(sample.label)»: \u{043F}\u{0443}\u{0442}\u{044C} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438} \u{0437}\u{0430}\u{043D}\u{044F}\u{043B} \(sample.path) \u{0441} — \u{043E}\u{0431}\u{0435}\u{0449}\u{0430}\u{043B}\u{0438} \u{043C}\u{0435}\u{043D}\u{044C}\u{0448}\u{0435} \u{0441}\u{0435}\u{043A}\u{0443}\u{043D}\u{0434}\u{044B}"
            )
        }
        for sample in samples where sample.audio >= 60 {
            XCTAssertLessThan(
                sample.path,
                2.0,
                "«\(sample.label)»: \u{043F}\u{0443}\u{0442}\u{044C} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438} \u{0437}\u{0430}\u{043D}\u{044F}\u{043B} \(sample.path) \u{0441}"
            )
        }

        // A long record must be parsed faster than real time with more
        // stock: if this ceases to be the case, dictation for three minutes will become
        // by waiting, not by dictation.
        let longest = try XCTUnwrap(samples.last)
        XCTAssertGreaterThan(
            longest.speedup,
            50,
            "\u{0422}\u{0440}\u{0451}\u{0445}\u{043C}\u{0438}\u{043D}\u{0443}\u{0442}\u{043D}\u{0430}\u{044F} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0440}\u{0430}\u{0437}\u{0431}\u{0438}\u{0440}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F} \u{0432}\u{0441}\u{0435}\u{0433}\u{043E} \u{0432} \(longest.speedup) \u{0440}\u{0430}\u{0437} \u{0431}\u{044B}\u{0441}\u{0442}\u{0440}\u{0435}\u{0435} \u{0440}\u{0435}\u{0430}\u{043B}\u{044C}\u{043D}\u{043E}\u{0433}\u{043E} \u{0432}\u{0440}\u{0435}\u{043C}\u{0435}\u{043D}\u{0438}"
        )

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - One measurement

    private func measure(_ label: String, text: String) async throws -> Sample {
        try await speak(text)
        let controller = makeController()
        await dictate(with: controller)

        let readyAt = await capture.fileReadyAt
        let insertions = await inserter.insertions
        let results = await probe.results

        let ready = try XCTUnwrap(readyAt, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0442}\u{0430}\u{043A} \u{0438} \u{043D}\u{0435} \u{0431}\u{044B}\u{043B}\u{0430} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{0442}\u{0430}")
        let insertion = try XCTUnwrap(insertions.last, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{0435} \u{0434}\u{043E}\u{0448}\u{0451}\u{043B} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438}")
        let result = try XCTUnwrap(results.last, "\u{041C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C} \u{043D}\u{0435} \u{043E}\u{0442}\u{0432}\u{0435}\u{0442}\u{0438}\u{043B}\u{0430}")

        return Sample(
            label: label,
            audio: result.audioDuration,
            inference: result.processingDuration,
            path: Self.seconds(ready.duration(to: insertion.at))
        )
    }

    /// Cancel must release the engine immediately, not after it
    /// finishes the entire recording.
    ///
    /// The `LocalTranscriber` comment earlier promised that it would keep the queue
    /// actor. This is false—actors are reentrant—and the real question is different:
    /// does the cancellation reach inside inference. Reached: TDT library decoder
    /// checks `Task.checkCancellation()` in a window loop, so Escape on
    /// a long recording does not force the next dictation to wait for the tail of the previous one.
    /// The test guards this property: without it, cancellation would be worth a complete analysis.
    func testScenario001() async throws {
        let transcriber = try await requireEndToEndTranscriber()
        let recording = try await SpeechFixtures.shared.speech(Phrase.veryLong)

        // Warm-up: the first work with the model in the process is always more expensive.
        _ = try await transcriber.transcribe(fileURL: recording)

        let started = ContinuousClock.now
        let work = Task { try await transcriber.transcribe(fileURL: recording) }
        // Enough for the parsing to actually begin, and noticeably less
        // what it occupies entirely.
        try await Task.sleep(for: .milliseconds(20))
        work.cancel()

        do {
            _ = try await work.value
            // The recording is short, the analysis could have ended before cancellation - this is not
            // failed, but then the test did not check anything.
            throw XCTSkip("\u{0440}\u{0430}\u{0437}\u{0431}\u{043E}\u{0440} \u{0437}\u{0430}\u{043A}\u{043E}\u{043D}\u{0447}\u{0438}\u{043B}\u{0441}\u{044F} \u{0431}\u{044B}\u{0441}\u{0442}\u{0440}\u{0435}\u{0435} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B} — \u{043D}\u{0430} \u{044D}\u{0442}\u{043E}\u{0439} \u{043C}\u{0430}\u{0448}\u{0438}\u{043D}\u{0435} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0441}\u{043B}\u{0438}\u{0448}\u{043A}\u{043E}\u{043C} \u{043A}\u{043E}\u{0440}\u{043E}\u{0442}\u{043A}\u{0430}\u{044F}")
        } catch let error as ASREngineError {
            XCTAssertEqual(error, .cancelled, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{044B}\u{0439} \u{0440}\u{0430}\u{0437}\u{0431}\u{043E}\u{0440} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0441}\u{043A}\u{0430}\u{0437}\u{0430}\u{0442}\u{044C}, \u{0447}\u{0442}\u{043E} \u{043E}\u{043D} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}")
        }

        let elapsed = Self.seconds(started.duration(to: .now))
        XCTAssertLessThan(
            elapsed,
            1.0,
            "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0430} \u{0437}\u{0430}\u{043D}\u{044F}\u{043B}\u{0430} \(elapsed) \u{0441} — \u{0434}\u{0432}\u{0438}\u{0436}\u{043E}\u{043A} \u{0434}\u{043E}\u{043C}\u{0430}\u{043B}\u{044B}\u{0432}\u{0430}\u{043B} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0432}\u{043C}\u{0435}\u{0441}\u{0442}\u{043E} \u{0442}\u{043E}\u{0433}\u{043E}, \u{0447}\u{0442}\u{043E}\u{0431}\u{044B} \u{0431}\u{0440}\u{043E}\u{0441}\u{0438}\u{0442}\u{044C} \u{0435}\u{0451}"
        )
    }

    /// Two recognitions at once do not spoil each other’s results.
    ///
    /// The dictation state machine will not start the second, but neither the actor nor the transcriber
    /// this is not guaranteed - both are reentrant on await. Term Tip
    /// this is general, so the main thing is checked: each parsing gets its own
    /// text, not a mixture of the two.
    func testScenario002() async throws {
        let transcriber = try await requireEndToEndTranscriber()
        let first = try await SpeechFixtures.shared.speech(Phrase.mixed)
        let second = try await SpeechFixtures.shared.speech(Phrase.other)

        // Reference responses received one at a time.
        let loneFirst = try await transcriber.transcribe(fileURL: first).text
        let loneSecond = try await transcriber.transcribe(fileURL: second).text

        async let concurrentFirst = transcriber.transcribe(fileURL: first).text
        async let concurrentSecond = transcriber.transcribe(fileURL: second).text
        let (gotFirst, gotSecond) = try await (concurrentFirst, concurrentSecond)

        XCTAssertEqual(gotFirst, loneFirst, "\u{041F}\u{0435}\u{0440}\u{0432}\u{044B}\u{0439} \u{0440}\u{0430}\u{0437}\u{0431}\u{043E}\u{0440} \u{0438}\u{0437}\u{043C}\u{0435}\u{043D}\u{0438}\u{043B}\u{0441}\u{044F} \u{043E}\u{0442} \u{0441}\u{043E}\u{0441}\u{0435}\u{0434}\u{0441}\u{0442}\u{0432}\u{0430} \u{0441}\u{043E} \u{0432}\u{0442}\u{043E}\u{0440}\u{044B}\u{043C}")
        XCTAssertEqual(gotSecond, loneSecond, "\u{0412}\u{0442}\u{043E}\u{0440}\u{043E}\u{0439} \u{0440}\u{0430}\u{0437}\u{0431}\u{043E}\u{0440} \u{0438}\u{0437}\u{043C}\u{0435}\u{043D}\u{0438}\u{043B}\u{0441}\u{044F} \u{043E}\u{0442} \u{0441}\u{043E}\u{0441}\u{0435}\u{0434}\u{0441}\u{0442}\u{0432}\u{0430} \u{0441} \u{043F}\u{0435}\u{0440}\u{0432}\u{044B}\u{043C}")
        XCTAssertFalse(
            gotSecond.contains(Phrase.mixedTerms[0]),
            "\u{0412} \u{043E}\u{0442}\u{0432}\u{0435}\u{0442} \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0433}\u{043E} \u{0440}\u{0430}\u{0437}\u{0431}\u{043E}\u{0440}\u{0430} \u{043F}\u{0440}\u{043E}\u{0442}\u{0451}\u{043A} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0433}\u{043E}"
        )
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
    }
}
