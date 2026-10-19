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
///
/// `dictation` decodes the file first, outside the timed interval, and then
/// times `LocalTranscriber.transcribe(samples:)`: the engine call a finished
/// take reaches. `file` times `transcribe(fileURL:)`, the import path, including
/// its own decoding. One JSON line answers each request. Text is printed
/// because scoring needs it; the harness, not this tool, decides what of it
/// may be kept. The process exits on end of input.
func serve(directory: URL) async throws {
    let adapter = TranscribeCppAdapter()
    // A research knob, not an app setting: terms one per line.
    if let path = ProcessInfo.processInfo.environment["WAI_ASR_VOCABULARY_FILE"] {
        let terms = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        await adapter.setVocabulary(terms)
    }
    let transcriber = LocalTranscriber(engine: adapter)
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
    ])

    let reader = AudioFileReader()
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }
        var reply: [String: Any] = [:]
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let path = request["path"] as? String else {
                throw ASREngineError.unsupportedAudioFormat("expected {\"path\": ...}")
            }
            reply["id"] = request["id"] ?? NSNull()
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
        reply["peakMemoryBytes"] = peakMemoryBytes()
        emit(reply)
    }
    await transcriber.unload()
}

private func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
