// fluidaudio-runner [--model v3|ultra] [--units ane|gpu|cpu] <manifest.jsonl> <out.jsonl>
//
// Loads one FluidAudio Parakeet model from a local directory once (no
// download, no network), then transcribes every manifest row in order.
// The first output row is {"id": "__load__", "load_seconds": ...}; the same
// figure is printed to stderr. Each later row is
// {"id", "text", "audio_seconds", "wall_seconds"}, where wall_seconds covers
// recognition of samples already in memory (file decoding is excluded).
//
// Models are read from $SPIKE_ROOT/fluidaudio/models/<model>, where
// SPIKE_ROOT defaults to ~/Library/Caches/OpenRambleSpike.

import CoreML
import FluidAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fluidaudio-runner: \(message)\n".utf8))
    exit(2)
}

func jsonLine(_ object: [String: Any]) -> Data {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        fail("cannot encode \(object)")
    }
    return data + Data("\n".utf8)
}

var model = "v3"
var units = "ane"
var positional: [String] = []
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--model", "--units":
        guard let value = arguments.next() else { fail("\(argument) needs a value") }
        if argument == "--model" { model = value } else { units = value }
    default: positional.append(argument)
    }
}
guard positional.count == 2 else {
    fail("usage: fluidaudio-runner [--model v3|ultra] [--units ane|gpu|cpu] <manifest.jsonl> <out.jsonl>")
}

let version: AsrModelVersion
switch model {
case "v3": version = .v3
case "ultra": version = .ultra
default: fail("unknown model \(model)")
}
// The encoder carries almost all compute; the decoder and joint stay on
// FluidAudio's defaults (CPU + Neural Engine), as in FluidAudio itself.
let encoderUnits: MLComputeUnits
switch units {
case "ane": encoderUnits = .cpuAndNeuralEngine
case "gpu": encoderUnits = .cpuAndGPU
case "cpu": encoderUnits = .cpuOnly
default: fail("unknown units \(units)")
}

let spikeRoot =
    ProcessInfo.processInfo.environment["SPIKE_ROOT"]
    ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/OpenRambleSpike").path
let modelDirectory = URL(fileURLWithPath: spikeRoot).appendingPathComponent("fluidaudio/models/\(model)")

guard let manifestText = try? String(contentsOfFile: positional[0], encoding: .utf8) else {
    fail("cannot read manifest")
}
let rows: [(id: String, path: String)] = manifestText.split(separator: "\n").compactMap {
    line -> (id: String, path: String)? in
    guard
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let id = object["id"].map({ "\($0)" }),
        let path = object["path"] as? String
    else { return nil }
    return (id, path)
}
FileManager.default.createFile(atPath: positional[1], contents: nil)
guard let out = FileHandle(forWritingAtPath: positional[1]) else { fail("cannot write \(positional[1])") }

let loadStart = Date()
let models: AsrModels
do {
    models = try AsrModels.loadLocal(from: modelDirectory, version: version, encoderComputeUnits: encoderUnits)
} catch {
    fail("load failed: \(error)")
}
let asr = AsrManager(config: .default, models: models)
let loadSeconds = Date().timeIntervalSince(loadStart)
FileHandle.standardError.write(Data("load_seconds \(String(format: "%.3f", loadSeconds))\n".utf8))
out.write(
    jsonLine([
        "id": "__load__", "load_seconds": loadSeconds, "runner": "fluidaudio 0.17.7",
        "model": model, "units": units,
    ]))

let converter = AudioConverter()
for row in rows {
    let samples: [Float]
    do {
        samples = try converter.resampleAudioFile(URL(fileURLWithPath: row.path))
    } catch {
        fail("cannot read \(row.path): \(error)")
    }
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let start = Date()
    let result: ASRResult
    do {
        result = try await asr.transcribe(samples, decoderState: &state)
    } catch {
        fail("\(row.id): \(error)")
    }
    let wall = Date().timeIntervalSince(start)
    out.write(
        jsonLine([
            "id": row.id, "text": result.text, "audio_seconds": Double(samples.count) / 16_000,
            "wall_seconds": wall,
        ]))
}
try? out.close()
