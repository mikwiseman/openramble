import DictationCore
import CryptoKit
import Foundation
import LocalASR

/// Paired, opt-in measurement; no transcript or input name is printed.
func benchmarkBatch(_ args: [String], directory: URL) async throws {
    guard args.count == 4, let seconds = Int(args[0]), [15, 30, 60].contains(seconds),
          let batchSize = Int(args[1]), [1, 2, 4, 8].contains(batchSize),
          let copies = Int(args[2]), [1, 2].contains(copies) else {
        throw ASREngineError.unsupportedAudioFormat("batch-benchmark <15|30|60> <1|2|4|8> <1|2 models> <audio>")
    }
    let samples = try AudioFileReader().samples(from: URL(fileURLWithPath: args[3]))
    let frames = seconds * 16_000
    guard samples.count >= frames else { throw ASREngineError.unsupportedAudioFormat("benchmark audio is too short") }
    let inputs = (0..<8).map { index in
        let start = (index * frames) % max(1, samples.count - frames + 1)
        return Array(samples[start..<(start + frames)])
    }
    let engines = (0..<copies).map { _ in TranscribeCppAdapter() }
    for engine in engines { try await engine.loadModels(from: directory) }
    do {
        _ = try await runBatch(inputs, engines: engines, size: batchSize)
        _ = try await runBatch(inputs, engines: [engines[0]], size: 1)
        for round in 0..<3 {
            let serial: ([ASRResult], Double)
            let batched: ([ASRResult], Double)
            if round.isMultiple(of: 2) {
                serial = try await timedBatch(inputs, engines: [engines[0]], size: 1)
                batched = try await timedBatch(inputs, engines: engines, size: batchSize)
            } else {
                batched = try await timedBatch(inputs, engines: engines, size: batchSize)
                serial = try await timedBatch(inputs, engines: [engines[0]], size: 1)
            }
            let parity = zip(serial.0, batched.0).allSatisfy { normalize($0.text) == normalize($1.text) }
            let payload: [String: Any] = [
                "round": round, "chunkSeconds": seconds, "batchSize": batchSize, "models": copies,
                "audioSeconds": seconds * inputs.count, "serialSeconds": serial.1,
                "batchSeconds": batched.1, "normalizedTextParity": parity,
                "exactTextParity": serial.0.map(\.text) == batched.0.map(\.text),
                "peakMemoryBytes": peakMemoryBytes(),
                "runtime": TranscribeCppAdapter.runtimeVersion,
                "textSHA256": digest(serial.0.map(\.text).map(normalize).joined(separator: "\n")),
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    } catch {
        for engine in engines { await engine.unload() }
        throw error
    }
    for engine in engines { await engine.unload() }
}

func benchmarkLatency(_ paths: [String], directory: URL) async throws {
    let inputs = try paths.map { try AudioFileReader().samples(from: URL(fileURLWithPath: $0), maximumDuration: 60) }
    let engine = TranscribeCppAdapter()
    try await engine.loadModels(from: directory)
    do {
        for input in inputs { _ = try await engine.transcribe(samples: input) }
        for round in 0..<20 {
            for (index, input) in inputs.enumerated() {
                let start = ContinuousClock.now
                let result = try await engine.transcribe(samples: input)
                let duration = start.duration(to: .now)
                let row: [String: Any] = [
                    "round": round, "input": index, "runtime": TranscribeCppAdapter.runtimeVersion,
                    "audioSeconds": result.audioDuration, "engineSeconds": result.processingDuration,
                    "wallSeconds": Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18,
                    "textSHA256": digest(normalize(result.text)), "peakMemoryBytes": peakMemoryBytes(),
                ]
                print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            }
        }
    } catch {
        await engine.unload()
        throw error
    }
    await engine.unload()
}

func benchmarkFiles(_ args: [String], directory: URL) async throws {
    guard args.count >= 2, let length = Int(args[0]), [15, 30, 60].contains(length) else {
        throw ASREngineError.unsupportedAudioFormat("file-benchmark <15|30|60> <audio>...")
    }
    let started = ContinuousClock.now
    let first = LocalTranscriber()
    try await first.prepare(modelDirectory: directory)
    let loaded = ContinuousClock.now
    do {
        try await FileTranscriber(transcriber: first, segmentSeconds: length).transcribe(
                files: args.dropFirst().map { URL(fileURLWithPath: $0) }, completed: { index, outcome in
            do {
                let result = try outcome.get()
                let row: [String: Any] = [
                    "input": index, "runtime": TranscribeCppAdapter.runtimeVersion,
                    "chunkSeconds": length, "batchSize": 1, "models": 1,
                    "audioSeconds": result.duration, "wordCount": result.words.count,
                    "textSHA256": digest(normalize(result.text)),
                    "timingBoundsValid": zip(result.words, result.words.dropFirst()).allSatisfy { $0.start <= $1.start }
                        && result.words.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= result.duration },
                    "lastWordEnd": result.words.last?.end ?? 0,
                    "coldWallSeconds": seconds(started.duration(to: .now)),
                    "processingWallSeconds": seconds(loaded.duration(to: .now)),
                    "peakMemoryBytes": peakMemoryBytes(),
                ]
                print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                fflush(stdout)
            } catch {
                print("{\"input\":\(index),\"failed\":true}")
            }
        })
    } catch {
        await first.unload()
        throw error
    }
    await first.unload()
}

private func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func normalize(_ text: String) -> String {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
}

private func timedBatch(_ inputs: [[Float]], engines: [TranscribeCppAdapter], size: Int) async throws -> ([ASRResult], Double) {
    let start = ContinuousClock.now
    let results = try await runBatch(inputs, engines: engines, size: size)
    let duration = start.duration(to: .now)
    return (results, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
}

private func runBatch(_ inputs: [[Float]], engines: [TranscribeCppAdapter], size: Int) async throws -> [ASRResult] {
    var results: [ASRResult] = []
    for wave in stride(from: 0, to: inputs.count, by: size * engines.count) {
        let pieces = try await withThrowingTaskGroup(of: (Int, [ASRResult]).self) { group in
            for (index, engine) in engines.enumerated() {
                let start = wave + index * size
                guard start < inputs.count else { continue }
                let batch = Array(inputs[start..<min(inputs.count, start + size)])
                group.addTask {
                    if batch.count == 1 {
                        return (index, [try await engine.transcribe(samples: batch[0], timestamps: true)])
                    }
                    return (index, try await engine.transcribe(batch: batch, timestamps: true).map { try $0.get() })
                }
            }
            var pieces: [(Int, [ASRResult])] = []
            for try await piece in group { pieces.append(piece) }
            return pieces.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        results.append(contentsOf: pieces)
    }
    return results
}
