import DictationCore
import Foundation
import LocalASR

// Model management and recognition from a terminal.
//
// This tool exists for the checks that cannot be written as unit tests: that a
// downloaded revision verifies against its manifest, and that recognition works
// with the network denied at the OS level. `scripts/test-zero-network.sh` runs
// `status` and `transcribe` inside a sandbox that refuses every outbound
// connection, which is how the offline promise in README.md is kept honest.
//
// It used to carry a research harness as well — encoder variants, accelerator
// placement, vocabulary scheduling, phase timings, WER scoring, a JSONL
// benchmark protocol. All of it measured a Core ML engine that no longer
// exists, and the measurements it produced are archived under
// research/asr-performance-2026-08/. What remains is what the product gates
// use.

func usage() -> Never {
    print("""
    asr-bench — local recognition from a terminal

    Commands:
      status                 what is installed, and where
      install                download and verify the model
      import <folder>        take the model from a prepared folder, no network
      delete                 remove the installed model
      transcribe <file>...   recognize audio files
      stream <file>...       recognize the way the app will: cut at pauses,
                             decode each piece, and report the tail latency

    Environment:
      WAI_MODELS_ROOT        install root (Application Support by default)
      WAI_ASR_MODEL_DIR      use this engine folder directly, past the store
    """)
    exit(64)
}

func modelsRoot() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"] else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
}

func makeStore() throws -> (ModelStore, ModelInstallLayout, ModelManifest) {
    let manifest = try ModelManifest.bundled()
    let layout = try ModelInstallLayout(manifest: manifest, root: modelsRoot())
    return (ModelStore(manifest: manifest, layout: layout), layout, manifest)
}

func formatBytes(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_000_000)
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Peak process memory, for the "the model fits in memory" gate.
func peakMemoryBytes() -> Int64 {
    var info = rusage()
    guard getrusage(RUSAGE_SELF, &info) == 0 else { return 0 }
    // On Apple platforms ru_maxrss is bytes, not kilobytes.
    return Int64(info.ru_maxrss)
}

func printState(_ state: ModelState, layout: ModelInstallLayout, manifest: ModelManifest) {
    switch state {
    case .notInstalled:
        print("Model not installed.")
        print("Will download \(formatBytes(manifest.totalByteCount)) into \(layout.installedDirectory.path)")
    case let .downloading(received, total):
        print("Downloading: \(formatBytes(received)) of \(formatBytes(total))")
    case let .verifying(checked, total):
        print("Verifying: \(checked) of \(total)")
    case let .ready(directory):
        print("Model ready: \(directory.path)")
        print("Revision: \(manifest.revision)")
        print("Files: \(manifest.files.count), \(formatBytes(manifest.totalByteCount))")
    case let .repairRequired(detail):
        print("Model needs recovery: \(detail)")
    case let .failed(error):
        print("Error: \(error)")
    case .deleting:
        print("Deleting…")
    }
}

func install(store: ModelStore, layout: ModelInstallLayout, manifest: ModelManifest) async -> Never {
    print("Downloading \(formatBytes(manifest.totalByteCount)) — \(manifest.files.count) file(s)")
    print("Source: \(manifest.repository) @ \(manifest.revision)")

    let states = await store.states()
    let monitor = Task {
        var lastShown = -1
        for await state in states {
            switch state {
            case let .downloading(received, total) where total > 0:
                let percent = Int(Double(received) / Double(total) * 100)
                if percent >= lastShown + 5 {
                    lastShown = percent
                    print("  \(percent)% — \(formatBytes(received))")
                }
            case let .verifying(checked, total):
                print("  verifying \(checked)/\(total)")
            default:
                break
            }
        }
    }

    await store.install()
    monitor.cancel()

    let finalState = await store.currentState()
    printState(finalState, layout: layout, manifest: manifest)
    exit(finalState.isReady ? 0 : 70)
}

/// Where the engine bundle lives: an explicitly named folder, or the store's.
func resolveEngineDirectory() async throws -> URL {
    if let explicit = ProcessInfo.processInfo.environment["WAI_ASR_MODEL_DIR"] {
        let directory = URL(fileURLWithPath: explicit, isDirectory: true)
        print("Engine folder given explicitly: \(directory.path)")
        return directory
    }
    let (store, layout, _) = try makeStore()
    guard await store.refreshState().isReady else {
        print("Model is not installed. Run: asr-bench install")
        exit(69)
    }
    return layout.engineDirectory
}

func prepareTranscriber() async throws -> LocalTranscriber {
    let engineDirectory = try await resolveEngineDirectory()
    let transcriber = LocalTranscriber(engine: TranscribeCppAdapter())
    let started = ContinuousClock.now
    try await transcriber.prepare(modelDirectory: engineDirectory)
    print(String(format: "Model loaded in %.2f s", seconds(started.duration(to: .now))))
    return transcriber
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let operands = Array(arguments.dropFirst())

switch command {
case "status":
    let (store, layout, manifest) = try makeStore()
    printState(await store.refreshState(), layout: layout, manifest: manifest)

case "install":
    let (store, layout, manifest) = try makeStore()
    if await store.refreshState().isReady {
        print("Model already installed: \(layout.installedDirectory.path)")
        exit(0)
    }
    await install(store: store, layout: layout, manifest: manifest)

case "import":
    guard let sourcePath = operands.first else { usage() }
    let (store, layout, manifest) = try makeStore()
    if await store.refreshState().isReady {
        print("Model already installed: \(layout.installedDirectory.path)")
        exit(0)
    }
    let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
    print("Taking the model from \(source.path)")
    print("Every one of the \(manifest.files.count) checksums is verified — the source of trust does not change")
    await store.importModel(from: source)
    let importedState = await store.currentState()
    printState(importedState, layout: layout, manifest: manifest)
    exit(importedState.isReady ? 0 : 70)

case "delete":
    let (store, layout, _) = try makeStore()
    await store.delete()
    print("Deleted: \(layout.modelDirectory.path)")

case "transcribe":
    guard !operands.isEmpty else { usage() }
    let transcriber = try await prepareTranscriber()

    for path in operands {
        let url = URL(fileURLWithPath: path)
        let started = ContinuousClock.now
        do {
            let result = try await transcriber.transcribe(fileURL: url)
            let wall = seconds(started.duration(to: .now))
            print("\n=== \(url.lastPathComponent) ===")
            print(result.text)
            print(
                String(
                    format: "audio %.2f s, wall %.2f s, rtf %.3f",
                    result.audioDuration,
                    wall,
                    result.audioDuration > 0 ? wall / result.audioDuration : 0
                )
            )
        } catch {
            print("\n=== \(url.lastPathComponent) ===")
            print("Error: \(error)")
            exit(70)
        }
    }
    print("\nprocess peak memory: \(formatBytes(peakMemoryBytes()))")

case "stream":
    // What the shipping path will do, measured on a file so it can be compared
    // against `transcribe` on the same file. The interesting number is not the
    // total — it is `tail`, because every segment before the last one is
    // decoded while the person is still talking and costs them nothing.
    guard !operands.isEmpty else { usage() }
    let transcriber = try await prepareTranscriber()
    let reader = AudioFileReader()

    for path in operands {
        let url = URL(fileURLWithPath: path)
        let samples: [Float]
        do {
            samples = try reader.samples(from: url)
        } catch {
            print("\n=== \(url.lastPathComponent) ===")
            print("Error reading: \(error)")
            exit(70)
        }

        // Exactly the loop the capture layer will run: fixed frames, peak per
        // frame, cut offsets back.
        var segmenter = SpeechSegmenter()
        var ranges: [Range<Int>] = []
        var segmentStart = 0
        var cursor = 0
        let frame = 2048
        while cursor < samples.count {
            let end = min(cursor + frame, samples.count)
            var peak: Float = 0
            for value in samples[cursor..<end] { peak = max(peak, abs(value)) }
            if let cut = segmenter.observe(peak: peak, count: end - cursor) {
                ranges.append(segmentStart..<(segmentStart + cut))
                segmentStart += cut
            }
            cursor = end
        }
        // The tail. Merged into the previous segment when it is too short to be
        // trusted on its own — the decoder is non-monotonic below two seconds.
        if segmentStart < samples.count {
            if !segmenter.pendingIsSubmittable, var last = ranges.popLast() {
                last = last.lowerBound..<samples.count
                ranges.append(last)
            } else {
                ranges.append(segmentStart..<samples.count)
            }
        }

        var pieces: [String] = []
        var totalEngine = 0.0
        var tailEngine = 0.0
        for (index, range) in ranges.enumerated() {
            let started = ContinuousClock.now
            let result = try await transcriber.transcribe(samples: Array(samples[range]))
            let wall = seconds(started.duration(to: .now))
            totalEngine += wall
            if index == ranges.count - 1 { tailEngine = wall }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append(text) }
        }

        let audioDuration = Double(samples.count) / 16_000
        print("\n=== \(url.lastPathComponent) ===")
        print(pieces.joined(separator: " "))
        print(
            String(
                format: "audio %.2f s, %d segments (%@), engine total %.2f s, tail %.2f s",
                audioDuration,
                ranges.count,
                ranges.map { String(format: "%.1f", Double($0.count) / 16_000) }
                    .joined(separator: " "),
                totalEngine,
                tailEngine
            )
        )
    }
    print("\nprocess peak memory: \(formatBytes(peakMemoryBytes()))")

default:
    usage()
}
