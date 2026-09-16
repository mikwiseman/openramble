import AVFoundation
import Foundation
import LocalASR

func diagnostic(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let usage = """
Usage: openramble [--model-dir DIRECTORY] [--] AUDIO_FILE...

Prints one transcript per file to stdout. Diagnostics go to stderr.
Uses OpenRamble's installed Parakeet GGUF model without changing it.
Audio formats: those supported by macOS AVFoundation, including WAV, M4A, MP3.

Environment:
  WAI_MODELS_ROOT        install root (Application Support by default)
"""

var files: [String] = []
var modelDirectory: String?
var positional = false
var args = Array(CommandLine.arguments.dropFirst())[...]
while let arg = args.popFirst() {
    if positional { files.append(arg); continue }
    switch arg {
    case "--help", "-h": print(usage); exit(0)
    case "--": positional = true
    case "--model-dir":
        guard let value = args.popFirst() else {
            diagnostic("--model-dir requires a directory"); exit(64)
        }
        modelDirectory = value
    default:
        guard !arg.hasPrefix("-") else {
            diagnostic("Unknown option: \(arg)\n\(usage)"); exit(64)
        }
        files.append(arg)
    }
}
guard !files.isEmpty else { diagnostic(usage); exit(64) }

// Reject inputs before the model loads: opening the header is milliseconds,
// loading the model is seconds, and a bad third file must not waste the first two.
for file in files {
    do {
        _ = try AVAudioFile(forReading: URL(fileURLWithPath: file))
    } catch {
        diagnostic("Cannot read audio file: \(file)"); exit(66)
    }
}

/// Where the engine bundle lives: an explicitly named folder, or the app's store.
func resolveEngineDirectory(explicit: String?) async throws -> URL {
    if let explicit {
        return URL(fileURLWithPath: explicit, isDirectory: true)
    }
    let manifest = try ModelManifest.bundled()
    let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    let layout = try ModelInstallLayout(manifest: manifest, root: root)
    let store = ModelStore(manifest: manifest, layout: layout)
    switch await store.inspectInstalledState() {
    case .ready:
        return layout.engineDirectory
    case .notInstalled:
        diagnostic("Model is not installed. Open OpenRamble and install it in Settings.")
        exit(69)
    case let .repairRequired(reason):
        diagnostic("Model is incomplete or damaged: \(reason). Finish installation or repair it in OpenRamble Settings.")
        exit(69)
    default:
        diagnostic("Model is unavailable. Check OpenRamble Settings.")
        exit(69)
    }
}

do {
    let directory = try await resolveEngineDirectory(explicit: modelDirectory)
    diagnostic("Model: \(directory.path)")
    let transcriber = LocalTranscriber(engine: TranscribeCppAdapter())
    try await transcriber.prepare(modelDirectory: directory)
    for file in files {
        let started = Date()
        let result = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: file))
        print(result.text)
        // stdout is fully buffered when redirected; a transcript reported as done
        // on stderr must already be in the file if the run is interrupted later.
        fflush(stdout)
        diagnostic(String(format: "%@: %.2f s audio, %.2f s elapsed", file,
                          result.audioDuration, Date().timeIntervalSince(started)))
    }
} catch {
    diagnostic("Transcription failed: \(error)")
    exit(70)
}
