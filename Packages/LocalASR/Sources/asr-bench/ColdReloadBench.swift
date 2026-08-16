import DictationCore
import Foundation
import LocalASR

// Reload-economics probe. The one scenario Handy wins today is
// ready-after-eviction, and the cost is CoreML/ANE respecialization at load
// time — not file reads. This subcommand produces the before/after numbers
// for the residency work; scripts/bench-cold-reload.sh orchestrates the
// process-level and cache-key scenarios around it.

/// One measured observation, serialized as a stable JSON line.
///
/// The formatter is pure so the schema is unit-testable: these numbers feed
/// before/after comparisons and must not drift by key order or locale.
struct ColdReloadReport {
    var scenario: String
    var placement: String
    var pressure: String
    var iteration: Int
    var prepareSeconds: Double
    var warmSeconds: Double?
    var totalSeconds: Double
    var modelPathKind: String
    var peakRSSBytes: Int64

    func jsonLine() -> String {
        var fields: [(String, String)] = [
            ("scenario", Self.quote(scenario)),
            ("placement", Self.quote(placement)),
            ("pressure", Self.quote(pressure)),
            ("iteration", String(iteration)),
            ("prepare_s", Self.number(prepareSeconds)),
        ]
        if let warmSeconds {
            fields.append(("warm_s", Self.number(warmSeconds)))
        }
        fields.append(("total_s", Self.number(totalSeconds)))
        fields.append(("model_path_kind", Self.quote(modelPathKind)))
        fields.append(("peak_rss_bytes", String(peakRSSBytes)))
        let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        return "{\(body)}"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func quote(_ value: String) -> String {
        // The bench writes only fixed labels; escaping stays for safety.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

func runColdReload(operands: [String]) async throws -> Never {
    var iterations = 3
    var scenario = "single-load"
    var index = 0
    while index < operands.count {
        switch operands[index] {
        case "--iterations":
            guard index + 1 < operands.count, let parsed = Int(operands[index + 1]),
                parsed > 0
            else { usage() }
            iterations = parsed
            index += 2
        case "--scenario":
            guard index + 1 < operands.count else { usage() }
            scenario = operands[index + 1]
            index += 2
        default:
            usage()
        }
    }

    let pressure = ProcessInfo.processInfo.environment["WAI_BENCH_PRESSURE"] ?? "none"
    let placement =
        ProcessInfo.processInfo.environment["WAI_ASR_ENCODER_PLACEMENT"] ?? "automatic"
    let modelPathKind =
        ProcessInfo.processInfo.environment["WAI_ASR_MODEL_DIR"] == nil
        ? "installed" : "explicit"
    // Progress goes to stderr so stdout stays parseable JSONL.
    let log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    switch scenario {
    case "single-load":
        // One process, one load, one warmup — the fresh-process and
        // cache-key-cold scenarios are this command re-executed by the script.
        let started = ContinuousClock.now
        let transcriber = try await prepareTranscriber(
            performConfiguredWarmup: false,
            logger: log
        )
        let prepared = ContinuousClock.now
        try await transcriber.warmUpInference()
        let warmed = ContinuousClock.now
        print(
            ColdReloadReport(
                scenario: scenario,
                placement: placement,
                pressure: pressure,
                iteration: 0,
                prepareSeconds: seconds(started.duration(to: prepared)),
                warmSeconds: seconds(prepared.duration(to: warmed)),
                totalSeconds: seconds(started.duration(to: warmed)),
                modelPathKind: modelPathKind,
                peakRSSBytes: peakMemoryBytes()
            ).jsonLine()
        )
        exit(0)

    case "warm-reload":
        // In-process unload→prepare→warm cycles: exactly what a residency
        // unload that keeps the worker alive will pay per comeback.
        let engineDirectory = try await resolveEngineDirectory(logger: log)
        let transcriber = try await prepareTranscriber(
            performConfiguredWarmup: false,
            logger: log
        )
        try await transcriber.warmUpInference()
        for iteration in 0..<iterations {
            await transcriber.unload()
            let started = ContinuousClock.now
            try await transcriber.prepare(modelDirectory: engineDirectory)
            let prepared = ContinuousClock.now
            try await transcriber.warmUpInference()
            let warmed = ContinuousClock.now
            print(
                ColdReloadReport(
                    scenario: scenario,
                    placement: placement,
                    pressure: pressure,
                    iteration: iteration,
                    prepareSeconds: seconds(started.duration(to: prepared)),
                    warmSeconds: seconds(prepared.duration(to: warmed)),
                    totalSeconds: seconds(started.duration(to: warmed)),
                    modelPathKind: modelPathKind,
                    peakRSSBytes: peakMemoryBytes()
                ).jsonLine()
            )
        }
        exit(0)

    default:
        usage()
    }
}
