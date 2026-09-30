import AVFoundation
import CryptoKit
import DictationCore
import Foundation
import LocalASR

private struct QualityManifest: Decodable {
    struct Input: Decodable {
        let id: String
        let path: String
        let canonical_path: String?
    }
    let fixtures: [Input]
}

private func readLocalFile(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try handle.readToEnd() ?? Data()
}

private func readQualityInputs(_ path: String) throws -> [QualityManifest.Input] {
    let manifest = try JSONDecoder().decode(QualityManifest.self,
        from: readLocalFile(URL(fileURLWithPath: path)))
    guard !manifest.fixtures.isEmpty,
          Set(manifest.fixtures.map(\.id)).count == manifest.fixtures.count else {
        throw ASREngineError.unsupportedAudioFormat("empty or duplicate benchmark inputs")
    }
    return manifest.fixtures
}

private func qualityJSON(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func pcmDigest(_ samples: [Float]) -> String {
    samples.withUnsafeBytes { bytes in
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// A research-only series: one model load, one warm-up, one recognition per
/// frozen input. Output is explicitly consented local benchmark data; the app
/// does not call this command or acquire another transcript store.
func benchmarkQuality(_ args: [String]) async throws {
    guard args.count == 2, let threads = Int32(args[1]), threads > 0,
          let modelPath = ProcessInfo.processInfo.environment["WAI_ASR_MODEL_DIR"] else {
        throw ASREngineError.unsupportedAudioFormat("quality-benchmark <manifest.json> <threads>; WAI_ASR_MODEL_DIR required")
    }
    let inputs = try readQualityInputs(args[0])
    let engine = TranscribeCppAdapter(threadCount: threads)
    let transcriber = LocalTranscriber(engine: engine)
    let loadStarted = ContinuousClock.now
    try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true))
    let loadSeconds = seconds(loadStarted.duration(to: .now))
    do {
        let warmStarted = ContinuousClock.now
        try await engine.warmUpInference()
        try qualityJSON([
            "type": "ready", "schema_version": 1,
            "runtime": TranscribeCppAdapter.runtimeVersion,
            "backend": await engine.activeBackend ?? "unavailable", "threads": threads,
            "load_seconds": loadSeconds, "warmup_seconds": seconds(warmStarted.duration(to: .now)),
            "process_peak_memory_bytes": peakMemoryBytes(),
            "memory_scope": "cumulative process high-water mark; fresh process per model",
            "recognition_scope": "current LocalTranscriber; default pause-aware long chunks",
        ])
        for input in inputs {
            let started = ContinuousClock.now
            do {
                // LocalTranscriber owns the current file/dictation behavior,
                // including the <=30s direct path and timed joins above it.
                let result = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: input.path))
                let wall = seconds(started.duration(to: .now))
                try qualityJSON([
                    "type": "result", "id": input.id, "status": "ok", "raw_text": result.text,
                    "audio_seconds": result.audioDuration, "wall_seconds": wall,
                    "engine_seconds": result.processingDuration,
                    "decode_seconds": result.decodingDuration,
                    "dispatch_seconds": result.engineDispatchDuration,
                    "queue_seconds": result.queueingDuration,
                    "process_peak_memory_bytes": peakMemoryBytes(),
                    "words": result.words.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] },
                ])
            } catch {
                try qualityJSON([
                    "type": "result", "id": input.id, "status": "error",
                    "error_type": String(reflecting: type(of: error)),
                    "wall_seconds": seconds(started.duration(to: .now)),
                    "process_peak_memory_bytes": peakMemoryBytes(),
                ])
            }
        }
        try qualityJSON(["type": "complete", "process_peak_memory_bytes": peakMemoryBytes()])
    } catch {
        await transcriber.unload()
        throw error
    }
    await transcriber.unload()
}

/// Freeze mono 16k Float32 WAV using the exact reader the app uses. All models
/// then receive the same canonical file. The original and PCM hashes are
/// retained by the preparation script, outside Git.
func canonicalizeQuality(_ args: [String]) throws {
    guard args.count == 1 else {
        throw ASREngineError.unsupportedAudioFormat("canonicalize <manifest.json>")
    }
    let inputs = try readQualityInputs(args[0])
    for input in inputs {
        guard let destination = input.canonical_path else {
            throw ASREngineError.unsupportedAudioFormat("canonical_path required")
        }
        let samples = try AudioFileReader().samples(from: URL(fileURLWithPath: input.path))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw ASREngineError.unsupportedAudioFormat("cannot allocate canonical audio")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
        do {
            // Release the writer before hashing or renaming, so the WAV header
            // is finalized rather than a hash of a still-open partial file.
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            func write() throws {
                let writer = try AVAudioFile(forWriting: temporary, settings: settings)
                try writer.write(from: buffer)
            }
            try write()
            // Do not overwrite an already sealed artifact with new bytes.
            if FileManager.default.fileExists(atPath: url.path) {
                guard try readLocalFile(temporary) == readLocalFile(url) else {
                    throw ASREngineError.unsupportedAudioFormat("canonical artifact already differs")
                }
                try FileManager.default.removeItem(at: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            let reread = try AudioFileReader().samples(from: url)
            guard pcmDigest(samples) == pcmDigest(reread) else {
                throw ASREngineError.unsupportedAudioFormat("canonical WAV changed PCM")
            }
            try qualityJSON(["id": input.id, "pcm_sha256": pcmDigest(samples),
                "sample_count": samples.count, "duration_seconds": Double(samples.count) / 16_000])
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
