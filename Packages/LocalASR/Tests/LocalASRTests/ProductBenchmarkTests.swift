import CryptoKit
import DictationCore
import Foundation
import XCTest
@testable import LocalASR

/// Opt-in public-fixture research. Never reads the microphone or the clipboard.
/// The configuration and output must be explicit; no product diagnostics change.
@MainActor
final class ProductBenchmarkTests: XCTestCase {
    struct Configuration: Decodable {
        let id: String
        let input: String
        let model: String
        let output: String
        let scratch: String
        let mode: String
        let pacing: String
        let workers: Int
    }

    func testPublicFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["OPENRAMBLE_PRODUCT_BENCHMARK_CONFIG"] else {
            throw XCTSkip("explicit public-fixture benchmark configuration required")
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard [1, 2, 4].contains(config.workers), ["realtime", "settled", "burst"].contains(config.pacing) else {
            throw BenchError.invalidConfiguration
        }
        let engines = (0..<config.workers).map { _ in TranscribeCppAdapter() }
        let transcribers = engines.map { LocalTranscriber(engine: $0) }
        let loadStart = ContinuousClock.now
        do {
            for transcriber in transcribers {
                try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: config.model))
            }
            let loadSeconds = elapsed(loadStart)
            let url = URL(fileURLWithPath: config.input)
            let warmStream = try await AudioFileStream(url: url)
            let warm = try await warmStream.read(frames: 5 * 16_000)
            for engine in engines { _ = try await engine.transcribe(samples: warm) }
            var row: [String: Any]
            switch config.mode {
            case "controller": row = try await controller(config, transcriber: transcribers[0])
            case "meeting": row = try await meeting(config, transcriber: transcribers[0])
            case "file": row = try await file(config, engines: engines)
            case "shipping-file": row = try await shippingFile(config, transcriber: transcribers[0])
            default: throw BenchError.invalidConfiguration
            }
            row["id"] = config.id
            row["mode"] = config.mode
            row["pacing"] = config.pacing
            row["workers"] = config.workers
            row["loadSeconds"] = loadSeconds
            row["runtime"] = TranscribeCppAdapter.runtimeVersion
            row["backend"] = await engines[0].activeBackend
            var usage = rusage()
            _ = getrusage(RUSAGE_SELF, &usage)
            row["peakRSSBytes"] = usage.ru_maxrss
            row["textSHA256"] = digest(row["text"] as? String ?? "")
            let output = URL(fileURLWithPath: config.output)
            try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .prettyPrinted]).write(to: output, options: .atomic)
            print("[public-fixture] completed \(config.id)")
        } catch {
            for transcriber in transcribers { await transcriber.unload() }
            throw error
        }
        for transcriber in transcribers { await transcriber.unload() }
    }

    private func controller(_ config: Configuration, transcriber: LocalTranscriber) async throws -> [String: Any] {
        let source = URL(fileURLWithPath: config.input)
        let samples = try AudioFileReader().samples(from: source)
        let take = URL(fileURLWithPath: config.scratch).appendingPathComponent("take-\(UUID()).wav")
        try FileManager.default.copyItem(at: source, to: take)
        defer { try? FileManager.default.removeItem(at: take) }
        let capture = PlaybackCapture(url: take, samples: samples)
        let sink = BenchmarkInserter()
        let probe = DecodeProbe(transcriber: transcriber)
        let controller = DictationController(capture: capture,
            transcribe: { try await transcriber.transcribe(fileURL: $0) },
            transcribeSamples: { try await probe.decode($0) },
            readSamples: { try await AudioFileReader().samplesOnDiskQueue(from: $0) },
            inserter: sink, overlay: BenchmarkOverlay(), sounds: BenchmarkSounds())
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.state != .listening, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard controller.state == .listening else { throw BenchError.startFailed }
        let feedStart = ContinuousClock.now
        let cuts = try await capture.play(pacing: config.pacing, probe: probe)
        let feedSeconds = elapsed(feedStart)
        let completedBefore = await probe.results.count
        let stop = ContinuousClock.now
        controller.stop()
        let deadline = stop.advanced(by: .seconds(120))
        while controller.state != .idle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let insertions = await sink.insertions
        guard controller.state == .idle, insertions.count == 1 else { throw BenchError.insertionFailed }
        let calls = await probe.results
        return ["text": insertions[0].text, "stopSeconds": duration(stop.duration(to: insertions[0].at)),
                "audioSeconds": Double(samples.count) / 16_000, "feedSeconds": feedSeconds,
                "cuts": cuts, "completedBeforeStop": completedBefore,
                "calls": calls.map { ["samples": $0.samples, "wallSeconds": $0.wall, "engineSeconds": $0.engine] },
                "maxFeedLatenessSeconds": await capture.maxLateness,
                "fileBacked": samples.count > 300 * 16_000]
    }

    private func file(_ config: Configuration, engines: [TranscribeCppAdapter]) async throws -> [String: Any] {
        let start = ContinuousClock.now
        let chunks = try await FileAudioChunks(url: URL(fileURLWithPath: config.input))
        var joiner = TimedTranscriptJoiner()
        var count = 0
        var chunkRows: [[String: Any]] = []
        // A bounded wave keeps no more than workers chunks in memory. Each
        // model owns its queue; all results are joined in original file order.
        while true {
            var wave: [FileAudioChunk] = []
            for _ in engines {
                if let chunk = try await chunks.next() { wave.append(chunk) }
            }
            if wave.isEmpty { break }
            let pieces = try await withThrowingTaskGroup(of: (Int, ASRResult).self) { group in
                for (index, chunk) in wave.enumerated() {
                    let engine = engines[index]
                    group.addTask { (index, try await engine.transcribe(samples: chunk.samples, timestamps: true)) }
                }
                var results: [(Int, ASRResult)] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }
            guard pieces.count == wave.count else { throw BenchError.missingChunk }
            for (index, result) in pieces {
                let chunk = wave[index]
                try joiner.append(result, chunk: chunk, duration: chunks.duration)
                chunkRows.append(["index": count, "startFrame": chunk.startFrame,
                                  "boundaryFrame": chunk.boundaryFrame, "endFrame": chunk.endFrame,
                                  "text": result.text, "textSHA256": digest(result.text),
                                  "engineSeconds": result.processingDuration])
                count += 1
            }
        }
        return transcriptRow(text: joiner.words.map(\.text).joined(separator: " "), words: joiner.words,
                             audio: chunks.duration, wall: elapsed(start), chunks: chunkRows)
    }

    private func shippingFile(_ config: Configuration, transcriber: LocalTranscriber) async throws -> [String: Any] {
        let start = ContinuousClock.now
        let result = TranscriptBox()
        try await FileTranscriber(transcriber: transcriber).transcribe(files: [URL(fileURLWithPath: config.input)]) { _, value in
            await result.set(value)
        }
        guard let value = await result.value else { throw BenchError.missingChunk }
        let transcript = try value.get()
        return transcriptRow(text: transcript.text, words: transcript.words, audio: transcript.duration,
                             wall: elapsed(start), chunks: [])
    }

    private func meeting(_ config: Configuration, transcriber: LocalTranscriber) async throws -> [String: Any] {
        let samples = try AudioFileReader().samples(from: URL(fileURLWithPath: config.input))
        let output = MeetingOutput()
        let queue = MeetingTranscriptionQueue(read: { ref in Array(samples[ref.startFrame..<ref.endFrame]) },
            decode: { try await transcriber.transcribe(samples: $0).text }, awaitTurn: {},
            emit: { ref, result in await output.append(ref, result) })
        var policy = MeetingSegmentPolicy(channel: .microphone)
        let start = ContinuousClock.now
        for cursor in stride(from: 0, to: samples.count, by: 320) {
            let end = min(cursor + 320, samples.count)
            if config.pacing == "realtime" {
                try await ContinuousClock().sleep(until: start.advanced(by: .seconds(Double(end) / 16_000)))
            }
            if let ref = policy.observe(peak: samples[cursor..<end].reduce(0) { max($0, abs($1)) }, count: end - cursor) {
                await queue.submit(ref)
                if config.pacing == "settled" { await queue.drain() }
            }
        }
        let before = await output.rows.count
        let stop = ContinuousClock.now
        if let tail = policy.flush() { await queue.submit(tail) }
        await queue.drain()
        let wall = elapsed(stop)
        let rows = await output.rows
        guard !rows.contains(where: { $0.failed }) else { throw BenchError.missingChunk }
        return ["text": rows.map(\.text).joined(separator: " "), "stopSeconds": wall,
                "audioSeconds": Double(samples.count) / 16_000, "completedBeforeStop": before,
                "segments": rows.count, "backlogAfterDrain": await queue.backlog]
    }

    private func transcriptRow(text: String, words: [ASRResult.Word], audio: Double,
                               wall: Double, chunks: [[String: Any]]) -> [String: Any] {
        ["text": text, "audioSeconds": audio, "processingSeconds": wall, "chunks": chunks,
         "words": words.map { ["text": $0.text, "start": $0.start, "end": $0.end] },
         "timingBoundsValid": zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start }
            && words.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= audio }]
    }
}

private enum BenchError: Error { case invalidConfiguration, startFailed, insertionFailed, missingChunk }
private func duration(_ value: Duration) -> Double {
    Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
}
private func elapsed(_ start: ContinuousClock.Instant) -> Double { duration(start.duration(to: .now)) }
private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

private actor TranscriptBox {
    var value: Result<FileTranscript, Error>?
    func set(_ value: Result<FileTranscript, Error>) { self.value = value }
}
private actor DecodeProbe {
    struct Row: Sendable { let samples: Int; let wall: Double; let engine: Double }
    let transcriber: LocalTranscriber
    var results: [Row] = []
    init(transcriber: LocalTranscriber) { self.transcriber = transcriber }
    func decode(_ samples: [Float]) async throws -> ASRResult {
        let start = ContinuousClock.now
        let result = try await transcriber.transcribe(samples: samples)
        results.append(Row(samples: samples.count, wall: elapsed(start), engine: result.processingDuration))
        return result
    }
}
private actor PlaybackCapture: AudioCapturing {
    let url: URL
    let samples: [Float]
    var sink: (@Sendable ([Float]) -> Void)?
    var consumed = 0
    var maxLateness = 0.0
    init(url: URL, samples: [Float]) { self.url = url; self.samples = samples }
    func setSegmentSink(_ sink: (@Sendable ([Float]) -> Void)?) { self.sink = sink }
    func startRecording() async throws -> URL { url }
    func stopRecording() async throws -> (url: URL, duration: TimeInterval) { (url, Double(samples.count) / 16_000) }
    func freezeRecording() async throws -> CapturedRecording {
        CapturedRecording(url: url, duration: Double(samples.count) / 16_000,
                          samples: samples.count > 300 * 16_000 ? nil : samples, consumedSampleCount: consumed)
    }
    func abortRecording() async {}
    func play(pacing: String, probe: DecodeProbe) async throws -> Int {
        var policy = SpeechSegmenter()
        let start = ContinuousClock.now
        var cuts = 0
        for cursor in stride(from: 0, to: samples.count, by: 2048) {
            let end = min(cursor + 2048, samples.count)
            if pacing == "realtime" {
                let due = start.advanced(by: .seconds(Double(end) / 16_000))
                try await ContinuousClock().sleep(until: due)
                maxLateness = max(maxLateness, duration(due.duration(to: .now)))
            }
            if let cut = policy.observe(peak: samples[cursor..<end].reduce(0) { max($0, abs($1)) }, count: end - cursor) {
                sink?(Array(samples[consumed..<(consumed + cut)]))
                consumed += cut
                cuts += 1
                if pacing == "settled" {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                    while await probe.results.count < cuts, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    guard await probe.results.count == cuts else { throw BenchError.missingChunk }
                }
            }
        }
        return cuts
    }
}
private actor BenchmarkInserter: TextInserting {
    struct Insertion: Sendable { let text: String; let at: ContinuousClock.Instant }
    var insertions: [Insertion] = []
    func insert(_ text: String, into target: TargetApplication?) async throws { insertions.append(Insertion(text: text, at: .now)) }
    func pressReturn() async throws {}
    nonisolated func frontmostApplication() -> TargetApplication? {
        TargetApplication(bundleIdentifier: "research.public-fixture-sink", processIdentifier: 0,
                          localizedName: "Public fixture sink")
    }
}
private actor BenchmarkOverlay: OverlayPresenting {
    func present(_ state: DictationState, elapsed: TimeInterval) async {}
    func dismiss() async {}
    func presentNotice(_ notice: DictationNotice) async {}
}
private actor BenchmarkSounds: Sounding { func playAttention() async {} }
private actor MeetingOutput {
    struct Row: Sendable { let text: String; let failed: Bool }
    var rows: [Row] = []
    func append(_ ref: MeetingSegmentRef, _ result: MeetingTranscriptionQueue.Outcome) {
        switch result {
        case let .decoded(text): rows.append(Row(text: text, failed: false))
        case let .failed(error): rows.append(Row(text: error, failed: true))
        }
    }
}
