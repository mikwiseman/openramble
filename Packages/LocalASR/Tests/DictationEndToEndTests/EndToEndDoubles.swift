import AVFoundation
import DictationCore
import Foundation
import LocalASR

// Exactly two edges remain dummy in end-to-end tests, which will be present in the test
// cannot: microphone and someone else's application. Everything in between - controller,
// recognizer-ready PCM, model, dictionary, text finishing - the present. File reading remains
// covered separately as the long-recording fallback.

/// A capture that delivers a pre-recorded file instead of a microphone.
///
/// The file is real, the format is the same as what `WAVWriter` writes (mono, 16 kHz, 16 bit),
/// the duration is read from the file and not assigned: otherwise the check is “too
/// short entry does not reach recognition” would check a fictitious number.
///
/// Each session receives its own copy of the fixture - the controller deletes the record after
/// recognition, and without a copy the second test would not have found the source.
actor FixturePlaybackCapture: AudioCapturing {
    private let directory: URL
    private var queue: [URL] = []
    private var lastFixture: URL?
    private var currentTake: URL?
    private var bufferedSamples: [Float]?

    private(set) var isRecording = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    /// All the files that the capture gave to the controller - you can see from them whether it cleaned up after itself.
    private(set) var takes: [URL] = []
    /// The moment when the recording file is ready: the start of the “file is ready → insert text” countdown.
    private(set) var fileReadyAt: ContinuousClock.Instant?

    init(directory: URL) {
        self.directory = directory
    }

    /// What to “say” in the following sessions. When the queue ends, the last one will be repeated.
    func enqueue(_ fixtures: [URL]) {
        queue.append(contentsOf: fixtures)
    }

    var leftoverTakes: [URL] {
        takes.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func startRecording() async throws -> URL {
        startCount += 1
        guard !isRecording else { throw AudioCaptureError.engineUnavailable("\u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0443}\u{0436}\u{0435} \u{0438}\u{0434}\u{0451}\u{0442}") }

        let fixture = queue.isEmpty ? lastFixture : queue.removeFirst()
        guard let fixture else { throw AudioCaptureError.engineUnavailable("\u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E} \u{043F}\u{0440}\u{043E}\u{0438}\u{0433}\u{0440}\u{044B}\u{0432}\u{0430}\u{0442}\u{044C}") }
        lastFixture = fixture

        let take = directory.appending(
            path: "take-\(UUID().uuidString).wav",
            directoryHint: .notDirectory
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture, to: take)
            // The production recorder accumulates this recognizer-ready PCM
            // while it writes the durable WAV. Prepare the fixture's equivalent
            // before the measured "take ready" boundary.
            bufferedSamples = try AudioFileReader().samples(from: take)
        } catch {
            bufferedSamples = nil
            throw AudioCaptureError.writeFailed(String(describing: error))
        }

        currentTake = take
        takes.append(take)
        isRecording = true
        return take
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        guard isRecording, let take = currentTake else { throw AudioCaptureError.notRecording }
        isRecording = false
        currentTake = nil

        let duration: TimeInterval
        do {
            let file = try AVAudioFile(forReading: take)
            duration = Double(file.length) / file.fileFormat.sampleRate
        } catch {
            throw AudioCaptureError.writeFailed(String(describing: error))
        }

        fileReadyAt = .now
        return (take, duration)
    }

    func takeBufferedSamples() async -> [Float]? {
        defer { bufferedSamples = nil }
        return bufferedSamples
    }

    /// Turns off the “microphone” and removes the file - just like `MicrophoneCapture` does.
    func abortRecording() async {
        abortCount += 1
        isRecording = false
        if let take = currentTake {
            try? FileManager.default.removeItem(at: take)
            currentTake = nil
        }
        bufferedSamples = nil
    }
}

/// An insert that remembers text instead of someone else's application.
actor RecordingInserter: TextInserting {
    struct Insertion: Sendable {
        let text: String
        let target: TargetApplication?
        /// The moment when the text reaches the insertion is the end of the delay countdown.
        let at: ContinuousClock.Instant
    }

    private let target: TargetApplication?
    private(set) var insertions: [Insertion] = []
    private(set) var returnPresses = 0

    init(
        target: TargetApplication? = TargetApplication(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 501,
            localizedName: "TextEdit"
        )
    ) {
        self.target = target
    }

    var texts: [String] { insertions.map(\.text) }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        insertions.append(Insertion(text: text, target: target, at: .now))
    }

    func pressReturn() async throws {
        returnPresses += 1
    }

    nonisolated func frontmostApplication() -> TargetApplication? { target }
}

/// An indicator that does not draw anything, but remembers everything.
actor RecordingOverlay: OverlayPresenting {
    private(set) var states: [DictationState] = []
    private(set) var notices: [DictationNotice] = []
    private(set) var dismissCount = 0

    func present(_ state: DictationState, elapsed: TimeInterval) async {
        states.append(state)
    }

    func dismiss() async { dismissCount += 1 }

    func presentNotice(_ notice: DictationNotice) async { notices.append(notice) }
}

/// The attention signal is counted, not played.
actor CountingSounds: Sounding {
    private(set) var attentionPlays = 0

    func playAttention() async { attentionPlays += 1 }
}

/// Observer of real recognition.
///
/// The only insertion in the battle chain, and it doesn’t change anything: it counts
/// requests, remembers the submitted file and the raw response of the model. Need a test
/// cancellations - the counter shows that the cancellation came AFTER recognition started, -
/// and the silence test, where the raw answer is checked, before the dictionary and refinement.
actor TranscriptionProbe {
    private(set) var calls = 0
    private(set) var files: [URL] = []
    /// Complete model responses: they contain both text and parsing time.
    private(set) var results: [ASRResult] = []
    private(set) var failures: [String] = []

    /// Raw text - before the dictionary and before finishing.
    var rawTexts: [String] { results.map(\.text) }

    func willStart(_ url: URL) {
        calls += 1
        files.append(url)
    }

    func willStartSamples() {
        calls += 1
    }

    func didFinish(_ result: ASRResult) {
        results.append(result)
    }

    func didFail(_ error: any Error) {
        failures.append(String(describing: error))
    }
}
