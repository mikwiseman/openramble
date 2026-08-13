import DictationCore
import Foundation
import LocalASR
import XCTest

/// Phrases that are “said” in end-to-end tests.
///
/// English terms are written in Latin letters - the same way a person pronounces them and
/// how the system voice reads them. This is exactly the main scenario of the product:
/// inside a Russian phrase, the model honestly writes the term in Cyrillic, and back it
/// returns a dictionary of replacements.
enum Phrase {
    /// Main scenario: Russian speech with English terms.
    static let mixed = "\u{042F} \u{043E}\u{0442}\u{043A}\u{0440}\u{044B}\u{043B} pull request \u{0432} GitHub, \u{043F}\u{0440}\u{043E}\u{0433}\u{043D}\u{0430}\u{043B} linter \u{0438} \u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438}\u{043B} deploy \u{043D}\u{0430} production."
    static let mixedTerms = ["pull request", "GitHub", "linter", "deploy", "production"]

    /// The “send” command is at the end of the phrase.
    static let send = "\u{041F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C} \u{043C}\u{043E}\u{0439} pull request, \u{043F}\u{043E}\u{0436}\u{0430}\u{043B}\u{0443}\u{0439}\u{0441}\u{0442}\u{0430}, \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}"
    /// The “new line” command at the end of the phrase.
    static let newLine = "\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}, \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}"

    /// A completely different topic: it shows if two dictations are mixed.
    static let other = "\u{0421}\u{043E}\u{0432}\u{0435}\u{0440}\u{0448}\u{0435}\u{043D}\u{043D}\u{043E} \u{0434}\u{0440}\u{0443}\u{0433}\u{0430}\u{044F} \u{0442}\u{0435}\u{043C}\u{0430}: \u{0437}\u{0430}\u{0432}\u{0442}\u{0440}\u{0430} \u{044F} \u{043B}\u{0435}\u{0447}\u{0443} \u{0432} \u{0411}\u{0435}\u{0440}\u{043B}\u{0438}\u{043D} \u{043D}\u{0430} \u{043A}\u{043E}\u{043D}\u{0444}\u{0435}\u{0440}\u{0435}\u{043D}\u{0446}\u{0438}\u{044E}."
    /// A word that is not found in any other phrase.
    static let otherMarker = "\u{0411}\u{0435}\u{0440}\u{043B}\u{0438}\u{043D}"

    /// A short phrase of about four seconds.
    static let short = "\u{0421}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F} \u{044F} \u{0445}\u{043E}\u{0447}\u{0443} \u{043A}\u{043E}\u{0440}\u{043E}\u{0442}\u{043A}\u{043E} \u{0440}\u{0430}\u{0441}\u{0441}\u{043A}\u{0430}\u{0437}\u{0430}\u{0442}\u{044C}, \u{043A}\u{0430}\u{043A} \u{0443}\u{0441}\u{0442}\u{0440}\u{043E}\u{0435}\u{043D} \u{043D}\u{0430}\u{0448} \u{0440}\u{0430}\u{0431}\u{043E}\u{0447}\u{0438}\u{0439} \u{0434}\u{0435}\u{043D}\u{044C}."

    /// Terms in indirect cases - this is how they are pronounced in Russian.
    /// Terms in indirect cases.
    ///
    /// “Python” is no longer here intentionally. Measurements on recent recordings showed that
    /// this entry has never worked - the model writes the word in place of Python
    /// “written,” but turned “Python compressed the prey” into “Python compressed the prey.”
    /// For the sake of a term that is still not caught, you cannot break the Russian language.
    static let declined = "\u{042F} \u{043F}\u{0438}\u{0448}\u{0443} \u{043D}\u{0430} \u{0441}\u{0432}\u{0438}\u{0444}\u{0442}\u{0435}, \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044F}\u{044E} \u{0432} \u{0431}\u{0438}\u{043B}\u{0434}\u{0435}, \u{0431}\u{0435}\u{0437} \u{0434}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}\u{0430}."
    static let declinedTerms = ["Swift", "build", "downtime"]

    /// A word similar to a term, but not a term.
    static let falseFriend = "\u{042F} \u{0436}\u{0438}\u{0432}\u{0443} \u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}, \u{043D}\u{0435}\u{0434}\u{0430}\u{043B}\u{0435}\u{043A}\u{043E} \u{043E}\u{0442} \u{043F}\u{0430}\u{0440}\u{043A}\u{0430}."

    /// English speech with an English command at the end.
    static let englishSend = "Please review my pull request send it"

    /// A paragraph of approximately thirty-six seconds.
    static let long = """
        \u{0421}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F} \u{044F} \u{0445}\u{043E}\u{0447}\u{0443} \u{043A}\u{043E}\u{0440}\u{043E}\u{0442}\u{043A}\u{043E} \u{0440}\u{0430}\u{0441}\u{0441}\u{043A}\u{0430}\u{0437}\u{0430}\u{0442}\u{044C}, \u{043A}\u{0430}\u{043A} \u{0443}\u{0441}\u{0442}\u{0440}\u{043E}\u{0435}\u{043D} \u{043D}\u{0430}\u{0448} \u{0440}\u{0430}\u{0431}\u{043E}\u{0447}\u{0438}\u{0439} \u{0434}\u{0435}\u{043D}\u{044C} \u{0438} \u{043F}\u{043E}\u{0447}\u{0435}\u{043C}\u{0443} \u{043C}\u{044B} \u{043F}\u{043E}\u{043C}\u{0435}\u{043D}\u{044F}\u{043B}\u{0438} \
        \u{043F}\u{043E}\u{0440}\u{044F}\u{0434}\u{043E}\u{043A} \u{0432}\u{044B}\u{043A}\u{043B}\u{0430}\u{0434}\u{043A}\u{0438}. \u{0423}\u{0442}\u{0440}\u{043E}\u{043C} \u{043C}\u{044B} \u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438}\u{043C}, \u{0447}\u{0442}\u{043E} \u{043D}\u{0430}\u{043A}\u{043E}\u{043F}\u{0438}\u{043B}\u{043E}\u{0441}\u{044C} \u{0437}\u{0430} \u{043D}\u{043E}\u{0447}\u{044C}, \u{0440}\u{0430}\u{0437}\u{0431}\u{0438}\u{0440}\u{0430}\u{0435}\u{043C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0438} \u{0438} \u{0440}\u{0435}\u{0448}\u{0430}\u{0435}\u{043C}, \
        \u{0447}\u{0442}\u{043E} \u{0431}\u{0435}\u{0440}\u{0451}\u{043C} \u{0432} \u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0443}. \u{0414}\u{043D}\u{0451}\u{043C} \u{043C}\u{044B} \u{043F}\u{0438}\u{0448}\u{0435}\u{043C} \u{043A}\u{043E}\u{0434}, \u{043E}\u{0431}\u{0441}\u{0443}\u{0436}\u{0434}\u{0430}\u{0435}\u{043C} \u{0440}\u{0435}\u{0448}\u{0435}\u{043D}\u{0438}\u{044F} \u{0438} \u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{043C} \u{0442}\u{043E}, \u{0447}\u{0442}\u{043E} \u{043D}\u{0430}\u{0448}\u{043B}\u{0438} \u{0432}\u{0447}\u{0435}\u{0440}\u{0430}. \
        \u{0412}\u{0435}\u{0447}\u{0435}\u{0440}\u{043E}\u{043C} \u{043C}\u{044B} \u{0441}\u{043E}\u{0431}\u{0438}\u{0440}\u{0430}\u{0435}\u{043C} \u{0441}\u{0431}\u{043E}\u{0440}\u{043A}\u{0443}, \u{043F}\u{0440}\u{043E}\u{0433}\u{043E}\u{043D}\u{044F}\u{0435}\u{043C} \u{0442}\u{0435}\u{0441}\u{0442}\u{044B} \u{0438} \u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438}\u{043C} \u{043D}\u{0430} \u{0433}\u{0440}\u{0430}\u{0444}\u{0438}\u{043A}\u{0438}. \u{0420}\u{0430}\u{043D}\u{044C}\u{0448}\u{0435} \u{0432}\u{044B}\u{043A}\u{043B}\u{0430}\u{0434}\u{043A}\u{0430} \
        \u{0437}\u{0430}\u{043D}\u{0438}\u{043C}\u{0430}\u{043B}\u{0430} \u{043F}\u{043E}\u{0447}\u{0442}\u{0438} \u{0447}\u{0430}\u{0441}, \u{0438} \u{043F}\u{043E}\u{043B}\u{043E}\u{0432}\u{0438}\u{043D}\u{0443} \u{044D}\u{0442}\u{043E}\u{0433}\u{043E} \u{0432}\u{0440}\u{0435}\u{043C}\u{0435}\u{043D}\u{0438} \u{043C}\u{044B} \u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E} \u{0436}\u{0434}\u{0430}\u{043B}\u{0438}. \u{0422}\u{0435}\u{043F}\u{0435}\u{0440}\u{044C} \u{043E}\u{043D}\u{0430} \u{0437}\u{0430}\u{043D}\u{0438}\u{043C}\u{0430}\u{0435}\u{0442} \u{0441}\u{0435}\u{043C}\u{044C} \
        \u{043C}\u{0438}\u{043D}\u{0443}\u{0442}, \u{0438} \u{043C}\u{044B} \u{043C}\u{043E}\u{0436}\u{0435}\u{043C} \u{0432}\u{044B}\u{043A}\u{043B}\u{0430}\u{0434}\u{044B}\u{0432}\u{0430}\u{0442}\u{044C} \u{043D}\u{0435}\u{0441}\u{043A}\u{043E}\u{043B}\u{044C}\u{043A}\u{043E} \u{0440}\u{0430}\u{0437} \u{0432} \u{0434}\u{0435}\u{043D}\u{044C}. \u{0413}\u{043B}\u{0430}\u{0432}\u{043D}\u{043E}\u{0435} \u{0438}\u{0437}\u{043C}\u{0435}\u{043D}\u{0435}\u{043D}\u{0438}\u{0435} \u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E}\u{0435}: \u{043C}\u{044B} \
        \u{043F}\u{0435}\u{0440}\u{0435}\u{0441}\u{0442}\u{0430}\u{043B}\u{0438} \u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} \u{0432}\u{0441}\u{0451} \u{0440}\u{0443}\u{043A}\u{0430}\u{043C}\u{0438} \u{0438} \u{043E}\u{043F}\u{0438}\u{0441}\u{0430}\u{043B}\u{0438} \u{043A}\u{0430}\u{0436}\u{0434}\u{044B}\u{0439} \u{0448}\u{0430}\u{0433} \u{0437}\u{0430}\u{0440}\u{0430}\u{043D}\u{0435}\u{0435}.
        """
    /// A word that is not in other phrases is a long entry mark.
    static let longMarker = "\u{0432}\u{044B}\u{043A}\u{043B}\u{0430}\u{0434}\u{043A}"

    /// The same paragraph five times - about three minutes.
    static var veryLong: String {
        Array(repeating: long, count: 5).joined(separator: "\n\n")
    }
}

/// General binding of the end-to-end test.
///
/// Collects the entire product: dictation controller from DictationCore, real
/// `LocalTranscriber` loaded with Parakeet model and real `TextPipeline`
/// with a starting dictionary. Exactly two edges are substituted: the microphone and someone else’s
/// application.
@MainActor
class EndToEndScenario: XCTestCase {
    private(set) var transcriber: LocalTranscriber!
    private(set) var capture: FixturePlaybackCapture!
    private(set) var inserter: RecordingInserter!
    private(set) var overlay: RecordingOverlay!
    private(set) var sounds: CountingSounds!
    private(set) var probe: TranscriptionProbe!
    private(set) var workspace: URL!

    override func setUp() async throws {
        try await super.setUp()

        // The model comes first: without it, the test does not fail, but is skipped.
        transcriber = try await requireEndToEndTranscriber()

        workspace = FileManager.default.temporaryDirectory
            .appending(path: "e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        capture = FixturePlaybackCapture(
            directory: workspace.appending(path: "records", directoryHint: .isDirectory)
        )
        inserter = RecordingInserter()
        overlay = RecordingOverlay()
        sounds = CountingSounds()
        probe = TranscriptionProbe()
    }

    override func tearDown() async throws {
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        try await super.tearDown()
    }

    // MARK: - Chain assembly

    /// A controller that has real everything except a microphone and someone else's application.
    func makeController(
        replacements: [DictionaryReplacement] = StarterDictionary.developer
    ) -> DictationController {
        let engine = transcriber!
        let watcher = probe!

        return DictationController(
            capture: capture,
            transcribe: { url in
                await watcher.willStart(url)
                do {
                    let result = try await engine.transcribe(fileURL: url)
                    await watcher.didFinish(result)
                    return result
                } catch {
                    await watcher.didFail(error)
                    throw error
                }
            },
            transcribeSamples: { samples in
                await watcher.willStartSamples()
                do {
                    let result = try await engine.transcribe(samples: samples)
                    await watcher.didFinish(result)
                    return result
                } catch {
                    await watcher.didFail(error)
                    throw error
                }
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { TextPipeline(replacements: replacements) }
        )
    }

    // MARK: - Sound

    /// Synthesize the phrase and put it in the capture queue.
    func speak(_ text: String, voice: SpeechVoice = .russian) async throws {
        let file = try await fixture { try await SpeechFixtures.shared.speech(text, voice: voice) }
        await capture.enqueue([file])
    }

    /// Queue an entry where the person is silent.
    func stayQuiet(seconds: Double) async throws {
        let file = try await fixture { try await SpeechFixtures.shared.silence(seconds: seconds) }
        await capture.enqueue([file])
    }

    /// Queue a snippet of real speech - “pressed and immediately released.”
    func speakBriefly(_ text: String, seconds: Double) async throws {
        let file = try await fixture {
            let full = try await SpeechFixtures.shared.speech(text)
            return try await SpeechFixtures.shared.truncated(full, toSeconds: seconds)
        }
        await capture.enqueue([file])
    }

    /// Synthesis is not available - the test is skipped with an explanation, rather than crashing.
    private func fixture(_ make: () async throws -> URL) async throws -> URL {
        do {
            return try await make()
        } catch let failure as FixtureFailure {
            throw XCTSkip("\u{0421}\u{043A}\u{0432}\u{043E}\u{0437}\u{043D}\u{043E}\u{0439} \u{0442}\u{0435}\u{0441}\u{0442} \u{043F}\u{0440}\u{043E}\u{043F}\u{0443}\u{0449}\u{0435}\u{043D} — \(failure.description)")
        }
    }

    // MARK: - Expectations

    /// Wait until the condition becomes true.
    ///
    /// Poll, not a fixed pause: the path through the real model takes then
    /// so much, then so much, and “sleep two hundred milliseconds” here would mean
    /// either a flashing test or extra seconds in each run.
    func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(60),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\u{041D}\u{0435} \u{0434}\u{043E}\u{0436}\u{0434}\u{0430}\u{043B}\u{0438}\u{0441}\u{044C}: \(what)", file: file, line: line)
    }

    /// Conduct one entire dictation: press, talk, release.
    func dictate(
        with controller: DictationController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitUntil("\u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043F}\u{043E}\u{0448}\u{043B}\u{0430}", file: file, line: line) { controller.state == .listening }
        controller.stop()
        await waitUntil("\u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{044F} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{043B}\u{0430}\u{0441}\u{044C}", file: file, line: line) { controller.state == .idle }
    }

    // MARK: - Checks

    /// Make sure that after the session there is no user voice left on the disk.
    ///
    /// Pending, not instantaneous, and this is the find of pass-through: deletion
    /// the entry is in the `defer` of the final task, and the state is “free”
    /// is set before it. On the way to cancel - from a different task altogether, and
    /// the gap stretches for the entire time the engine is running. Return delay
    /// printed in the cancel test: this is the measured size of the gap.
    @discardableResult
    func assertNoRecordingsLeft(
        timeout: Duration = .seconds(15),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Duration {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await capture.leftoverTakes.isEmpty { return started.duration(to: .now) }
            try? await Task.sleep(for: .milliseconds(2))
        }

        let leftovers = await capture.leftoverTakes
        XCTFail(
            "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043E}\u{0441}\u{0442}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{043D}\u{0430} \u{0434}\u{0438}\u{0441}\u{043A}\u{0435}: \(leftovers.map(\.lastPathComponent))",
            file: file,
            line: line
        )
        return started.duration(to: .now)
    }

    /// Duration in milliseconds - for printing in diagnostics.
    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Make sure that the user is not shown any complaints.
    func assertNoFailureNotices(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let notices = await overlay.notices
        XCTAssertEqual(
            notices.filter { $0.kind != .info }.map(\.message),
            [],
            "\u{0421}\u{0446}\u{0435}\u{043D}\u{0430}\u{0440}\u{0438}\u{0439} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{043F}\u{0440}\u{043E}\u{0439}\u{0442}\u{0438} \u{0431}\u{0435}\u{0437} \u{043F}\u{0440}\u{0435}\u{0434}\u{0443}\u{043F}\u{0440}\u{0435}\u{0436}\u{0434}\u{0435}\u{043D}\u{0438}\u{0439}",
            file: file,
            line: line
        )
    }
}

// MARK: - Text parsing

extension String {
    /// Positions of occurrences - they show whether the word order has been preserved.
    func position(of needle: String) -> Int? {
        range(of: needle, options: [.caseInsensitive]).map {
            distance(from: startIndex, to: $0.lowerBound)
        }
    }

    func containsInsensitive(_ needle: String) -> Bool {
        range(of: needle, options: [.caseInsensitive]) != nil
    }

    /// How many times it was encountered - this shows whether the long entry was received in its entirety.
    func occurrences(of needle: String) -> Int {
        var count = 0
        var cursor = startIndex
        while let found = range(of: needle, options: [.caseInsensitive], range: cursor..<endIndex) {
            count += 1
            cursor = found.upperBound
        }
        return count
    }

    var wordCount: Int {
        split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
