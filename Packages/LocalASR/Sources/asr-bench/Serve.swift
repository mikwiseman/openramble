import DictationCore
import Foundation
import LocalASR

/// The scorecard's warm lane: one model load, then one request per stdin line.
///
/// Prepared exactly as the app prepares its engine — load, then a silent
/// warm-up inference — so the first measured request is a steady-state one,
/// as the first dictation after launch is. Each request is a JSON object:
///
///     {"id": "...", "path": "/abs/file.wav", "mode": "dictation" | "file"}
///     {"id": "...", "mode": "warm"}
///
/// `dictation` decodes the file first, outside the timed interval, and then
/// times `LocalTranscriber.transcribe(samples:)`: the engine call a finished
/// take reaches. `file` times `transcribe(fileURL:)`, the import path, including
/// its own decoding. `warm` is the app's key-down hook: when the engine has
/// been idle past `LocalTranscriber.idleWarmupThreshold` it starts the warm-up
/// and answers at once; a `warmed` event follows when the warm-up ends, and a
/// `dictation` sent meanwhile waits for it exactly as a take does. One JSON
/// line answers each request. Text is printed because scoring needs it; the
/// harness, not this tool, decides what of it may be kept. Every answer
/// carries `idleSeconds` from before the request and the process's cumulative
/// `diskReadBytes`. The process exits on end of input.
func serve(directory: URL) async throws {
    let transcriber = LocalTranscriber(engine: TranscribeCppAdapter())
    let loadStarted = ContinuousClock.now
    try await transcriber.prepare(modelDirectory: directory)
    let loadSeconds = seconds(loadStarted.duration(to: .now))
    let warmupStarted = ContinuousClock.now
    try await transcriber.warmUpInference()
    emit([
        "event": "ready",
        "loadSeconds": loadSeconds,
        "warmupSeconds": seconds(warmupStarted.duration(to: .now)),
        "runtime": TranscribeCppAdapter.runtimeVersion,
        "peakMemoryBytes": peakMemoryBytes(),
        "footprintBytes": footprintBytes().current,
        "peakFootprintBytes": footprintBytes().peak,
    ])

    let reader = AudioFileReader()
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }
        var reply: [String: Any] = [:]
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw ASREngineError.unsupportedAudioFormat("expected a JSON object")
            }
            reply["id"] = request["id"] ?? NSNull()
            let idle = await transcriber.idleDuration
            reply["idleSeconds"] = idle.map(seconds) ?? NSNull()
            if request["mode"] as? String == "warm" {
                let due = LocalTranscriber.shouldWarmUnderVoice(afterIdle: idle)
                reply["warming"] = due
                if due {
                    let id = request["id"] as? String ?? ""
                    Task {
                        let started = ContinuousClock.now
                        var event: [String: Any] = ["event": "warmed", "id": id]
                        do { try await transcriber.warmUpInference() } catch { event["error"] = String(describing: error) }
                        event["seconds"] = seconds(started.duration(to: .now))
                        event["diskReadBytes"] = ProcessDiskReads.bytesRead() ?? 0
                        emit(event)
                    }
                }
                reply["diskReadBytes"] = ProcessDiskReads.bytesRead() ?? 0
                emit(reply)
                continue
            }
            guard let path = request["path"] as? String else {
                throw ASREngineError.unsupportedAudioFormat("expected {\"path\": ...}")
            }
            let url = URL(fileURLWithPath: path)
            let result: ASRResult
            let started: ContinuousClock.Instant
            switch request["mode"] as? String ?? "dictation" {
            case "file":
                started = .now
                result = try await transcriber.transcribe(fileURL: url)
            case "dictation":
                let samples = try reader.samples(from: url)
                started = .now
                result = try await transcriber.transcribe(samples: samples)
            default:
                throw ASREngineError.unsupportedAudioFormat("mode is dictation or file")
            }
            reply["wallSeconds"] = seconds(started.duration(to: .now))
            reply["text"] = result.text
            reply["audioSeconds"] = result.audioDuration
            reply["engineSeconds"] = result.processingDuration
        } catch {
            reply["error"] = String(describing: error)
        }
        reply["diskReadBytes"] = ProcessDiskReads.bytesRead() ?? 0
        reply["peakMemoryBytes"] = peakMemoryBytes()
        let footprint = footprintBytes()
        reply["footprintBytes"] = footprint.current
        reply["peakFootprintBytes"] = footprint.peak
        emit(reply)
    }
    await transcriber.unload()
}

private func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
