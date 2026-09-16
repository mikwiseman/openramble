import Darwin
import Foundation
import LocalASR

func diagnostic(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let usage = """
Usage: openramble AUDIO_FILE [--format txt|json|srt|vtt]
       openramble AUDIO_FILE... --output-dir DIRECTORY [--format FORMAT]
       openramble --check-model

Uses the installed Parakeet model offline, even when the GUI is closed.
Results go to stdout or separate files in --output-dir; progress goes to stderr.
Existing output files are never overwritten. One failed input does not stop others.
Long jobs yield while OpenRamble is dictating. Ctrl-C stops the job safely.

Options:
  --format FORMAT        txt (default), json, srt or vtt
  --output-dir DIRECTORY write separate transcripts here
  --model-dir DIRECTORY  use a prepared folder containing the GGUF model
  --check-model          check model availability without loading it
  --                     treat remaining arguments as file paths
  -h, --help             show this help

Environment:
  WAI_MODELS_ROOT         model install root (Application Support by default)
"""

struct CLIError: Error {
    let code: Int32
    let message: String
}

struct Options: Sendable {
    var files: [String] = []
    var modelDirectory: String?
    var outputDirectory: String?
    var format: TranscriptFormat = .txt
    var checkModel = false
    var help = false

    init(_ arguments: [String]) throws {
        var args = arguments[...]
        var positional = false
        func value(_ option: String) throws -> String {
            guard let value = args.popFirst(), !value.isEmpty else {
                throw CLIError(code: 64, message: "\(option) requires a value")
            }
            return value
        }
        while let arg = args.popFirst() {
            if positional { files.append(arg); continue }
            switch arg {
            case "--help", "-h": help = true
            case "--": positional = true
            case "--check-model": checkModel = true
            case "--model-dir": modelDirectory = try value(arg)
            case "--output-dir": outputDirectory = try value(arg)
            case "--format":
                let name = try value(arg)
                guard let format = TranscriptFormat(rawValue: name) else {
                    throw CLIError(code: 64, message: "Unknown format: \(name)")
                }
                self.format = format
            default:
                guard !arg.hasPrefix("-") else { throw CLIError(code: 64, message: "Unknown option: \(arg)") }
                files.append(arg)
            }
        }
        guard help || checkModel || !files.isEmpty else { throw CLIError(code: 64, message: usage) }
        guard files.count <= 1 || outputDirectory != nil else {
            throw CLIError(code: 64, message: "Use --output-dir for multiple files so each keeps its own transcript.")
        }
    }
}

func resolveEngineDirectory(explicit: String?) async throws -> URL {
    if let explicit {
        let url = URL(fileURLWithPath: explicit, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        guard files.filter({ $0.pathExtension.lowercased() == "gguf" }).count == 1 else {
            throw CLIError(code: 69, message: "The model directory must contain exactly one readable GGUF model.")
        }
        return url
    }
    let manifest = try ModelManifest.bundled()
    let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    let layout = try ModelInstallLayout(manifest: manifest, root: root)
    let store = ModelStore(manifest: manifest, layout: layout)
    switch await store.inspectInstalledState() {
    case .ready: return layout.engineDirectory
    case .notInstalled:
        throw CLIError(code: 69, message: "Model is not installed. Open OpenRamble and install it in Settings.")
    case let .repairRequired(reason):
        throw CLIError(code: 69, message: "Model is incomplete or damaged: \(reason). Finish installation or repair it in OpenRamble Settings.")
    default:
        throw CLIError(code: 69, message: "Model is unavailable. Check OpenRamble Settings.")
    }
}

struct Job: Sendable {
    let input: URL
    let output: URL?
}

@MainActor
func run(_ options: Options) async throws -> Int32 {
    if options.help { print(usage); return 0 }
    let directory = try await resolveEngineDirectory(explicit: options.modelDirectory)
    if options.checkModel {
        diagnostic("Model is installed and available.")
        if options.files.isEmpty { return 0 }
    }
    let output = options.outputDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    var names: Set<String> = []
    var jobs: [Job] = []
    var failures = 0
    for file in options.files {
        let input = URL(fileURLWithPath: file)
        let stem = input.deletingPathExtension().lastPathComponent
        var name = "\(stem).\(options.format.rawValue)"
        var suffix = 2
        while !names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
            name = "\(stem)-\(suffix).\(options.format.rawValue)"
            suffix += 1
        }
        let destination = output?.appending(path: name)
        if let destination, FileManager.default.fileExists(atPath: destination.path) {
            diagnostic("Already exists, left unchanged: \(destination.path)")
            failures += 1
        } else {
            jobs.append(Job(input: input, output: destination))
        }
    }
    guard !jobs.isEmpty else { return 1 }
    let priority = try DictationPriority()
    try await priority.waitForTurn()
    let transcriber = LocalTranscriber()
    do {
        try await transcriber.prepare(modelDirectory: directory)
        let processor = FileTranscriber(transcriber: transcriber, priority: priority)
        try await processor.transcribe(files: jobs.map(\.input), progress: { [count = jobs.count] index, seconds, total in
            diagnostic("Transcribing \(index + 1)/\(count): \(Int(min(100, seconds / max(total, 0.001) * 100)))%")
        }, completed: { @MainActor index, outcome in
            let job = jobs[index]
            do {
                let transcript = try outcome.get()
                if let destination = job.output {
                    try options.format.write(transcript, to: destination)
                    diagnostic("Saved: \(destination.path)")
                } else {
                    try FileHandle.standardOutput.write(contentsOf: options.format.render(transcript))
                }
            } catch {
                failures += 1
                diagnostic("Failed: \(job.input.path): \(error)")
            }
        })
    } catch {
        await transcriber.unload()
        throw error
    }
    await transcriber.unload()
    return failures == 0 ? 0 : 1
}

do {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    signal(SIGPIPE, SIG_IGN)
    let work = Task { try await run(options) }
    let signals = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { @Sendable in work.cancel() }
        source.resume()
        return source
    }
    do {
        let code = try await work.value
        signals.forEach { $0.cancel() }
        exit(code)
    } catch {
        signals.forEach { $0.cancel() }
        throw error
    }
} catch is CancellationError {
    diagnostic("Interrupted. Completed output files have been kept.")
    exit(130)
} catch let error as CLIError {
    diagnostic(error.message)
    exit(error.code)
} catch {
    diagnostic("Transcription failed: \(error)")
    exit(70)
}
