import AVFoundation
import CryptoKit
import Foundation

/// Voices that synthesize sound for end-to-end tests.
///
/// There is exactly one Russian system voice in macOS, so there are “different speakers” here
/// unattainable: synthesis gives smooth speech without pauses, slips and noise. This is the main thing
/// restriction of the entire check, and it is recorded in the report.
enum SpeechVoice: String, Sendable {
    case russian = "Milena"
    case english = "Samantha"
}

enum FixtureFailure: Error, CustomStringConvertible {
    case toolMissing(String)
    case voiceMissing(String)
    case toolFailed(tool: String, status: Int32, output: String)
    case unreadable(String)

    var description: String {
        switch self {
        case let .toolMissing(tool):
            return "\u{0432} \u{0441}\u{0438}\u{0441}\u{0442}\u{0435}\u{043C}\u{0435} \u{043D}\u{0435}\u{0442} \(tool) — \u{0441}\u{0438}\u{043D}\u{0442}\u{0435}\u{0437}\u{0438}\u{0440}\u{043E}\u{0432}\u{0430}\u{0442}\u{044C} \u{0437}\u{0432}\u{0443}\u{043A} \u{043D}\u{0435}\u{0447}\u{0435}\u{043C}"
        case let .voiceMissing(voice):
            return "\u{0432} \u{0441}\u{0438}\u{0441}\u{0442}\u{0435}\u{043C}\u{0435} \u{043D}\u{0435} \u{0443}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043B}\u{0435}\u{043D} \u{0433}\u{043E}\u{043B}\u{043E}\u{0441} \(voice): \u{0421}\u{0438}\u{0441}\u{0442}\u{0435}\u{043C}\u{043D}\u{044B}\u{0435} \u{043D}\u{0430}\u{0441}\u{0442}\u{0440}\u{043E}\u{0439}\u{043A}\u{0438} → \u{0423}\u{043D}\u{0438}\u{0432}\u{0435}\u{0440}\u{0441}\u{0430}\u{043B}\u{044C}\u{043D}\u{044B}\u{0439} \u{0434}\u{043E}\u{0441}\u{0442}\u{0443}\u{043F} → \u{0420}\u{0435}\u{0447}\u{044C}"
        case let .toolFailed(tool, status, output):
            return "\(tool) \u{0432}\u{0435}\u{0440}\u{043D}\u{0443}\u{043B} \(status): \(output)"
        case let .unreadable(reason):
            return "\u{043D}\u{0435} \u{0447}\u{0438}\u{0442}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C}: \(reason)"
        }
    }
}

/// Audio for end-to-end tests: synthesized by the macOS system voice.
///
/// Finished files are cached between runs. `say` is deterministic - one and the same
/// the same phrase gives the same file, byte-by-byte, - therefore the cache is safe, and the key
/// serves as a hash of voice and text: editing the text gives a new file, an outdated cache
/// there is nothing to slip.
actor SpeechFixtures {
    static let shared = SpeechFixtures()

    private let sampleRate = 16_000

    private let cache = FileManager.default.temporaryDirectory
        .appending(path: "openramble-e2e-audio", directoryHint: .isDirectory)

    /// Synthesize a phrase and return a WAV in dictation format: mono, 16 kHz, 16 bit.
    func speech(_ text: String, voice: SpeechVoice = .russian) throws -> URL {
        let destination = try cached(named: "\(voice.rawValue)-\(digest(voice.rawValue, text))")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        // The voice is checked separately: `say` with someone else's voice name reads the text
        // in the default voice, and instead of an intelligible pass, the test would receive
        // English voice acting of a Russian phrase and an incomprehensible fall.
        try requireVoice(voice)

        return try build(into: destination) { work in
            // The text is passed as a file, not as an argument: three-minute fixture in
            // the command line does not fit, and line breaks in the argument are lost.
            let source = work.appending(path: "text.txt", directoryHint: .notDirectory)
            try Data(text.utf8).write(to: source)

            let aiff = work.appending(path: "speech.aiff", directoryHint: .notDirectory)
            let wav = work.appending(path: "speech.wav", directoryHint: .notDirectory)
            try Self.run("/usr/bin/say", ["-v", voice.rawValue, "-f", source.path, "-o", aiff.path])
            try Self.run(
                "/usr/bin/afconvert",
                ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
            )
            return wav
        }
    }

    /// A recording in which a person is silent.
    ///
    /// Not absolute zero, but a quiet background of about −60 dBFS: this is exactly what the microphone hears
    /// in a quiet room. At absolute zero the check would be weaker - “the model does not
    /// invents a phrase” you need to ask about a real noise floor.
    func silence(seconds: Double) throws -> URL {
        let destination = try cached(named: "silence-\(Int(seconds * 1000))ms")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        return try build(into: destination) { work in
            var generator = SystemNoise(seed: 0x5DEE_CE66_D000_0001)
            let frames = Int(Double(sampleRate) * seconds)
            let samples = (0..<frames).map { _ in generator.next() }
            let wav = work.appending(path: "silence.wav", directoryHint: .notDirectory)
            try Self.writeWAV(samples: samples, sampleRate: sampleRate, to: wav)
            return wav
        }
    }

    /// Trim the recording to the required duration without changing the format.
    ///
    /// Needed for testing “pressed and immediately released”: snippet of real speech
    /// more honest than the generated click.
    func truncated(_ source: URL, toSeconds seconds: Double) throws -> URL {
        let destination = try cached(
            named: "cut-\(Int(seconds * 1000))ms-\(digest("cut", source.lastPathComponent))"
        )
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let head = try Self.readSamples(from: source, limit: Int(Double(sampleRate) * seconds))
        return try build(into: destination) { work in
            let wav = work.appending(path: "cut.wav", directoryHint: .notDirectory)
            try Self.writeWAV(samples: head, sampleRate: sampleRate, to: wav)
            return wav
        }
    }

    // MARK: - Internal

    /// List of installed voices - the system is asked once.
    private var installedVoices: Set<String>?

    private func requireVoice(_ voice: SpeechVoice) throws {
        if installedVoices == nil {
            let listing = try Self.output(of: "/usr/bin/say", ["-v", "?"])
            // Each line begins with the name of the voice, followed by the language code.
            installedVoices = Set(
                listing.split(separator: "\n").compactMap {
                    $0.split(separator: " ").first.map(String.init)
                }
            )
        }
        guard installedVoices?.contains(voice.rawValue) == true else {
            throw FixtureFailure.voiceMissing(voice.rawValue)
        }
    }

    private func cached(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache.appending(path: "\(name).wav", directoryHint: .notDirectory)
    }

    /// Collect the file in a temporary folder and move it into place in one motion.
    ///
    /// A half file in the cache would be worse than a missing file: next run
    /// would take it for ready.
    private func build(into destination: URL, make: (URL) throws -> URL) throws -> URL {
        let work = cache.appending(path: "build-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let produced = try make(work)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: produced, to: destination)
        return destination
    }

    private func digest(_ parts: String...) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Run the tool, discarding the output.
    private static func run(_ tool: String, _ arguments: [String]) throws {
        _ = try output(of: tool, arguments)
    }

    /// Run the tool and return its output.
    private static func output(of tool: String, _ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw FixtureFailure.toolMissing(tool)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let errors = Pipe()
        process.standardOutput = out
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw FixtureFailure.toolFailed(tool: tool, status: -1, output: String(describing: error))
        }

        // The output is read before waiting: a full pipe would stop the process,
        // and waiting for it to complete is us.
        let produced = out.fileHandleForReading.readDataToEndOfFile()
        let complaints = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FixtureFailure.toolFailed(
                tool: tool,
                status: process.terminationStatus,
                output: String(decoding: complaints, as: UTF8.self)
            )
        }
        return String(decoding: produced, as: UTF8.self)
    }

    /// Read the record in 16-bit samples.
    private static func readSamples(from url: URL, limit: Int) throws -> [Int16] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw FixtureFailure.unreadable(error.localizedDescription)
        }

        let frames = AVAudioFrameCount(min(Int(file.length), limit))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else {
            throw FixtureFailure.unreadable("\u{0432} \(url.lastPathComponent) \u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E} \u{0447}\u{0438}\u{0442}\u{0430}\u{0442}\u{044C}")
        }

        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            throw FixtureFailure.unreadable(error.localizedDescription)
        }
        guard let channel = buffer.floatChannelData?[0] else {
            throw FixtureFailure.unreadable("\u{043D}\u{0435}\u{0442} \u{0434}\u{0430}\u{043D}\u{043D}\u{044B}\u{0445} \u{043A}\u{0430}\u{043D}\u{0430}\u{043B}\u{0430}")
        }

        return (0..<Int(buffer.frameLength)).map { index in
            Int16(max(-1, min(1, channel[index])) * 32_767)
        }
    }

    /// Record WAV with exactly the same title as the dictation writes it.
    private static func writeWAV(samples: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data()
        let payload = samples.count * 2
        let byteRate = sampleRate * 2

        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1) // PCM uncompressed
        appendUInt16(1) // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(2) // block = one 16-bit sample
        appendUInt16(16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(payload))

        data.reserveCapacity(data.count + payload)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }
}

/// The noise floor of a quiet room - reproduced before the countdown.
///
/// Your own generator, not the system one: the fixture must be the same in each
/// run, otherwise “the model didn’t invent anything” would be checked every time for
/// different sound.
private struct SystemNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Int16 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        // ±32 out of 32767 - about −60 dBFS.
        return Int16(truncatingIfNeeded: Int(state >> 40) % 65) - 32
    }
}
