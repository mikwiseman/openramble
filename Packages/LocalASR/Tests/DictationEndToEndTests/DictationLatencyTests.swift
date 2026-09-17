import DictationCore
import Foundation
import LocalASR
import XCTest

/// Measurement of the promise “text appears in less than a second.”
///
/// The entire common path is measured, not just one recognition: from the moment when the finished
/// take and its in-memory PCM are ready until the text reaches insertion. This segment includes
/// the model itself, a dictionary of replacements and finishing the text - exactly what a person
/// expects with the key released. WAV reopening is the capped long-take fallback and is tested
/// independently.
@MainActor
final class DictationLatencyTests: EndToEndScenario {
    /// Opt-in distribution for the complete controller stop-to-insertion path.
    /// Audio capture and the destination app are fixtures, the model is real.
    /// Can run beside the packaged CLI to exercise the cross-process signal.
    func testStopToInsertionDistribution() async throws {
        #if arch(x86_64)
        throw XCTSkip("Apple Silicon latency budget; Intel CPU performance is experimental")
        #else
        guard ProcessInfo.processInfo.environment["OPENRAMBLE_LATENCY_DISTRIBUTION"] == "1" else {
            throw XCTSkip("opt-in paired latency benchmark")
        }
        let priority = try DictationPriority()
        var samples: [Double] = []
        for round in 0..<21 {
            try await speak(Phrase.short)
            let controller = makeController()
            try priority.setActive(true)
            controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
            await waitUntil("listening") { controller.state == .listening }
            // A real speaker holds the lock while talking, before key-up.
            try await Task.sleep(for: .seconds(1))
            let released = ContinuousClock.now
            controller.stop()
            await waitUntil("inserted") { controller.state == .idle }
            let insertions = await inserter.insertions
            XCTAssertEqual(insertions.count, round + 1, "every measured dictation must insert a new result")
            let insertion = try XCTUnwrap(insertions.last)
            try priority.setActive(false)
            if round > 0 { samples.append(Self.seconds(released.duration(to: insertion.at))) }
            try await Task.sleep(for: .milliseconds(100))
        }
        samples.sort()
        let median = (samples[9] + samples[10]) / 2
        print("[stop-to-insertion] runtime=\(TranscribeCppAdapter.runtimeVersion) n=\(samples.count) p50=\(median) p95=\(samples[18]) max=\(samples[19])")
        XCTAssertLessThan(samples[18], 1)
        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
        #endif
    }

    private struct Sample {
        let label: String
        /// Recording duration according to the engine data.
        let audio: TimeInterval
        /// How much did the model itself take?
        let inference: TimeInterval
        /// The entire path “take ready → text at insertion”.
        let path: TimeInterval
        /// Scheduler return spans measured around the real engine path.
        let poolReturn: TimeInterval
        let mainActorReturn: TimeInterval
        let engineDispatch: TimeInterval

        /// How many times is the path shorter than the record itself?
        var speedup: Double { path > 0 ? audio / path : 0 }

        var line: String {
            let name = label.padding(toLength: 10, withPad: " ", startingAt: 0)
            let numbers = String(
                format: "%8.2f \u{0441} | %9.3f \u{0441} | %9.3f \u{0441} | %7.3f \u{0441} | %7.3f \u{0441} | %7.3f \u{0441} | %6.0f×",
                audio,
                inference,
                path,
                poolReturn,
                mainActorReturn,
                engineDispatch,
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
        #if arch(x86_64)
        throw XCTSkip("Apple Silicon latency budget; Intel CPU performance is experimental")
        #else
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

        print("\n| \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C}     |    \u{0430}\u{0443}\u{0434}\u{0438}\u{043E} | \u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}. |     \u{0432}\u{0435}\u{0441}\u{044C} \u{043F}\u{0443}\u{0442}\u{044C} | pool return | main return | engine queue | \u{0431}\u{044B}\u{0441}\u{0442}\u{0440}\u{0435}\u{0435} \u{0420}\u{0412} |")
        print("|------------|----------|------------|---------------|-------------|-------------|--------------|------------|")
        for sample in samples { print(sample.line) }
        print(Self.loadAverageLine())
        print("")

        for sample in samples where sample.audio < 60 {
            XCTAssertLessThan(
                sample.path,
                1.0,
                "«\(sample.label)»: \u{043F}\u{0443}\u{0442}\u{044C} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438} \u{0437}\u{0430}\u{043D}\u{044F}\u{043B} \(sample.path) \u{0441} — \u{043E}\u{0431}\u{0435}\u{0449}\u{0430}\u{043B}\u{0438} \u{043C}\u{0435}\u{043D}\u{044C}\u{0448}\u{0435} \u{0441}\u{0435}\u{043A}\u{0443}\u{043D}\u{0434}\u{044B}"
            )
        }
        // Long-form is where the one-thread decoder is slower than the
        // eight-thread number this budget used to record. A 184-second take
        // measured 3.39 s (54x) on the runtime default. The same fixture
        // through asr-bench at one thread was 7.27 s, and the product path on
        // this machine now measures 6.8-7.9 s (23-27x) with queue wait at
        // zero. The budget records that measurement with headroom. Short and
        // half-minute dictations stay under a second; that promise is
        // unchanged.
        for sample in samples where sample.audio >= 60 {
            XCTAssertLessThan(
                sample.path,
                12.0,
                "«\(sample.label)»: \u{043F}\u{0443}\u{0442}\u{044C} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438} \u{0437}\u{0430}\u{043D}\u{044F}\u{043B} \(sample.path) \u{0441}"
            )
        }

        // A long recording must still be recognised far faster than real time,
        // or a three-minute dictation becomes a wait rather than a dictation.
        //
        // The floor was 50x, then 30x, when inference moved onto a thread of
        // its own. That thread costs a little throughput and removes
        // multi-second waits under load (29.66 s to reach an engine that then
        // worked 1.31 s). 30x on three minutes is six seconds, which the
        // one-thread decoder does not meet: three quiet runs on this machine
        // were 6.81 s, 7.04 s and 7.88 s (27x, 26x, 23x). 15x is twelve
        // seconds, which still fails a genuine collapse and matches the
        // measured path with the same kind of headroom the 3.39 s figure used
        // to have.
        let longest = try XCTUnwrap(samples.last)
        XCTAssertGreaterThan(
            longest.speedup,
            15,
            "\u{0422}\u{0440}\u{0451}\u{0445}\u{043C}\u{0438}\u{043D}\u{0443}\u{0442}\u{043D}\u{0430}\u{044F} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0440}\u{0430}\u{0437}\u{0431}\u{0438}\u{0440}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F} \u{0432}\u{0441}\u{0435}\u{0433}\u{043E} \u{0432} \(longest.speedup) \u{0440}\u{0430}\u{0437} \u{0431}\u{044B}\u{0441}\u{0442}\u{0440}\u{0435}\u{0435} \u{0440}\u{0435}\u{0430}\u{043B}\u{044C}\u{043D}\u{043E}\u{0433}\u{043E} \u{0432}\u{0440}\u{0435}\u{043C}\u{0435}\u{043D}\u{0438}"
        )

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
        #endif
    }

    // MARK: - One measurement

    private func measure(_ label: String, text: String) async throws -> Sample {
        try await speak(text)
        let controller = makeController()
        var speedReport: DictationSpeedReport?
        controller.onSpeed = { speedReport = $0 }
        await dictate(with: controller)

        let readyAt = await capture.fileReadyAt
        let insertions = await inserter.insertions
        let results = await probe.results

        let ready = try XCTUnwrap(readyAt, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0442}\u{0430}\u{043A} \u{0438} \u{043D}\u{0435} \u{0431}\u{044B}\u{043B}\u{0430} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{0442}\u{0430}")
        let insertion = try XCTUnwrap(insertions.last, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{0435} \u{0434}\u{043E}\u{0448}\u{0451}\u{043B} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438}")
        let result = try XCTUnwrap(results.last, "\u{041C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C} \u{043D}\u{0435} \u{043E}\u{0442}\u{0432}\u{0435}\u{0442}\u{0438}\u{043B}\u{0430}")
        let phases = try XCTUnwrap(speedReport?.phases, "\u{041D}\u{0435}\u{0442} scheduler attribution for the real engine path")
        XCTAssertEqual(phases.returnFrameWasMainThread, false)

        return Sample(
            label: label,
            audio: result.audioDuration,
            inference: result.processingDuration,
            path: Self.seconds(ready.duration(to: insertion.at)),
            poolReturn: Self.seconds(try XCTUnwrap(phases.poolReturn)),
            mainActorReturn: Self.seconds(try XCTUnwrap(phases.mainActorReturn)),
            engineDispatch: Self.seconds(try XCTUnwrap(phases.engineDispatch))
        )
    }

    /// Parakeet checks its abort callback between requests, not during one
    /// encoder graph. Long-file jobs bound that wait with short chunks.
    func testLongFileCancellationStopsAtNextChunkAndDoesNotComplete() async throws {
        let transcriber = try await requireEndToEndTranscriber()
        let recording = try await SpeechFixtures.shared.speech(Phrase.veryLong)
        let started = ContinuousClock.now
        let work = Task {
            try await FileTranscriber(transcriber: transcriber).transcribe(files: [recording]) { _, _ in
                XCTFail("an interrupted file must not publish a complete transcript")
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        work.cancel()
        do {
            try await work.value
            XCTFail("cancelled job returned success")
        } catch is CancellationError {
        } catch let error as ASREngineError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertLessThan(Self.seconds(started.duration(to: .now)), 1.0,
                          "cancellation must not decode the rest of the long file")
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

    /// Load at assertion time, so a slow run can be told apart from a slow
    /// engine when someone reads a release log months later.
    private static func loadAverageLine() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "" }
        return String(format: "load %.2f %.2f %.2f", loads[0], loads[1], loads[2])
    }
}
