import CoreML
import CryptoKit
import Darwin
import Foundation
import FluidAudio

private let protocolVersion = 1

private struct Arguments {
    let modelDirectory: String

    init(_ values: [String]) throws {
        guard values.count == 1 else {
            throw NSError(
                domain: "all-closed-jsonl-server",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "usage: all-closed-jsonl-server MODEL_DIR"]
            )
        }
        modelDirectory = values[0]
    }
}

private struct CachedFixture {
    let samples: [Float]
    let language: Language?
    let pcmSHA256: String
    let cache: TempClosedChunkCache
    let offlineTextSHA256: String
    let offlineTimingSHA256: String
}

private func normalizedHash(_ text: String) -> String {
    let normalized = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return sha256(Data(normalized.utf8))
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sampleData(_ samples: [Float]) -> Data {
    samples.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func stableHash<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256(try encoder.encode(value))
}

private func nanoseconds(_ duration: Duration) -> UInt64 {
    let seconds = UInt64(max(0, duration.components.seconds))
    let fractional = UInt64(max(0, duration.components.attoseconds / 1_000_000_000))
    return seconds * 1_000_000_000 + fractional
}

private func peakRSSBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
}

private func jsonLine(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func response(
    id: Any,
    command: String,
    fields: [String: Any] = [:]
) -> [String: Any] {
    var value: [String: Any] = [
        "id": id,
        "ok": true,
        "protocol_version": protocolVersion,
        "command": command,
    ]
    for (key, item) in fields { value[key] = item }
    return value
}

private func errorResponse(id: Any, detail: String) -> [String: Any] {
    [
        "id": id,
        "ok": false,
        "protocol_version": protocolVersion,
        "error": detail,
    ]
}

private func string(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
        throw NSError(
            domain: "all-closed-jsonl-server",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "request requires non-empty \(key)"]
        )
    }
    return value
}

@main
private enum AllClosedJSONLServer {
    static func main() async throws {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        ModelHub.offlineMode = true

        var manager: AsrManager?
        var loaded = false
        var prewarmed = false
        var fixtures: [String: CachedFixture] = [:]
        var loadAudit: [String: Any] = [:]
        var preloadAudits: [String: [String: Any]] = [:]
        var runAudits: [String: [[String: Any]]] = [:]
        let defaultLanguageRaw = ProcessInfo.processInfo.environment["WAI_ASR_LANGUAGE"]
        let auditPath = ProcessInfo.processInfo.environment["OR_CLOSED_CACHE_AUDIT_PATH"]

        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let request: [String: Any]
            do {
                let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8))
                guard let object = parsed as? [String: Any] else {
                    throw NSError(
                        domain: "all-closed-jsonl-server",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "request must be a JSON object"]
                    )
                }
                request = object
            } catch {
                try jsonLine(errorResponse(id: NSNull(), detail: error.localizedDescription))
                continue
            }

            let id: Any = request["id"] ?? NSNull()
            let command = request["command"] as? String ?? ""
            do {
                switch command {
                case "load":
                    guard !loaded else {
                        throw NSError(
                            domain: "all-closed-jsonl-server",
                            code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "model is already loaded"]
                        )
                    }
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = .all
                    let started = ContinuousClock.now
                    let models = try await AsrModels.load(
                        from: URL(fileURLWithPath: arguments.modelDirectory, isDirectory: true),
                        configuration: configuration,
                        version: .v3,
                        encoderPrecision: .int8,
                        encoderComputeUnits: .all
                    )
                    let created = AsrManager(
                        config: ASRConfig(
                            tdtConfig: TdtConfig(maxTokensPerChunk: 600),
                            parallelChunkConcurrency: 4,
                            melChunkContext: false,
                            dualDecodeArbitration: false
                        )
                    )
                    try await created.loadModels(models)
                    manager = created
                    loaded = true
                    let loadNS = nanoseconds(started.duration(to: .now))
                    let effectiveSettings: [String: Any] = [
                        "compute_units": "all",
                        "encoder_precision": "int8_palettized6bit",
                        "encoder_compute_units": "all",
                        "mel_chunk_context": false,
                        "parallel_chunk_concurrency": 4,
                        "max_tokens_per_chunk": 600,
                        "dual_decode": false,
                        "preprocessor_array_return_reset_data": false,
                        "vocabulary_enabled": false,
                        "encoder_placement": "automatic",
                        "vocabulary_scheduling": "candidateRegions",
                        "language": defaultLanguageRaw ?? NSNull(),
                    ]
                    loadAudit = [
                        "load_ns": loadNS,
                        "model_directory": arguments.modelDirectory,
                        "effective_settings": effectiveSettings,
                        "peak_rss_bytes": peakRSSBytes(),
                    ]
                    try jsonLine(
                        response(
                            id: id,
                            command: command,
                            fields: [
                                "load_ns": loadNS,
                                "model_directory": arguments.modelDirectory,
                                "effective_settings": effectiveSettings,
                                "model": [
                                    "engine_directory": arguments.modelDirectory,
                                    "model_id": "parakeet-tdt-0.6b-v3",
                                    "revision": "aed02740059203c4a87495924f685de3722ae9ce",
                                ],
                                "vocabulary_model": NSNull(),
                                "peak_rss_bytes": peakRSSBytes(),
                            ]
                        )
                    )

                case "prewarm":
                    guard let manager, loaded else {
                        throw NSError(
                            domain: "all-closed-jsonl-server",
                            code: 6,
                            userInfo: [NSLocalizedDescriptionKey: "load must complete first"]
                        )
                    }
                    let started = ContinuousClock.now
                    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                    _ = try await manager.transcribe(
                        [Float](repeating: 0, count: ASRConstants.sampleRate),
                        decoderState: &state,
                        language: Language(rawValue: "en")
                    )
                    prewarmed = true
                    try jsonLine(
                        response(
                            id: id,
                            command: command,
                            fields: [
                                "prewarm_ns": nanoseconds(started.duration(to: .now)),
                                "peak_rss_bytes": peakRSSBytes(),
                            ]
                        )
                    )

                case "preload":
                    guard let manager, loaded else {
                        throw NSError(
                            domain: "all-closed-jsonl-server",
                            code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "load must complete first"]
                        )
                    }
                    let key = try string(request, "key")
                    let path = try string(request, "path")
                    let canonicalPath = try string(request, "canonical_path")
                    let languageRaw = (request["language"] as? String) ?? defaultLanguageRaw
                    let language = languageRaw.flatMap(Language.init(rawValue:))
                    guard languageRaw == nil || language != nil else {
                        throw NSError(
                            domain: "all-closed-jsonl-server",
                            code: 8,
                            userInfo: [NSLocalizedDescriptionKey: "unsupported language"]
                        )
                    }
                    let converter = AudioConverter()
                    let samples = try converter.resampleAudioFile(path: path)
                    let bytes = sampleData(samples)
                    let pcmSHA = sha256(bytes)
                    try bytes.write(to: URL(fileURLWithPath: canonicalPath), options: .atomic)

                    let cache = try await manager.tempPrecomputeAllProvablyClosedChunks(
                        samples,
                        language: language
                    )
                    var offlineState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                    let offline = try await manager.transcribe(
                        samples,
                        decoderState: &offlineState,
                        language: language
                    )
                    let cached = try await manager.tempTranscribeUsingAllClosedChunks(
                        samples,
                        cache: cache,
                        language: language
                    )
                    let offlineTextSHA = sha256(Data(offline.text.utf8))
                    let offlineTimingSHA = try stableHash(offline.tokenTimings ?? [])
                    let cachedTextSHA = sha256(Data(cached.text.utf8))
                    let cachedTimingSHA = try stableHash(cached.tokenTimings ?? [])
                    guard offlineTextSHA == cachedTextSHA, offlineTimingSHA == cachedTimingSHA else {
                        throw NSError(
                            domain: "all-closed-jsonl-server",
                            code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "OR cached/offline parity mismatch"]
                        )
                    }
                    fixtures[key] = CachedFixture(
                        samples: samples,
                        language: language,
                        pcmSHA256: pcmSHA,
                        cache: cache,
                        offlineTextSHA256: offlineTextSHA,
                        offlineTimingSHA256: offlineTimingSHA
                    )
                    let metadata: [[String: Any]] = cache.metadata.map {
                        [
                            "index": $0.index,
                            "chunk_start_sample": $0.chunkStartSample,
                            "input_start_sample": $0.inputStartSample,
                            "input_end_sample": $0.inputEndSample,
                            "stable_start_prefix_sample_count": $0.stableStartPrefixSampleCount,
                            "earliest_safe_prefix_sample_count": $0.earliestSafePrefixSampleCount,
                            "token_count": $0.tokenCount,
                            "input_byte_count": $0.inputByteCount,
                            "precompute_wall_ms": $0.precomputeWallMilliseconds,
                        ]
                    }
                    let preloadAudit: [String: Any] = [
                        "key": key,
                        "source_path": path,
                        "canonical_path": canonicalPath,
                        "sample_rate": ASRConstants.sampleRate,
                        "sample_count": samples.count,
                        "audio_duration_ns": UInt64(samples.count) * 1_000_000_000
                            / UInt64(ASRConstants.sampleRate),
                        "pcm_f32le_sha256": pcmSHA,
                        "language": languageRaw ?? NSNull(),
                        "cached_closed_window_count": cache.cachedWindowCount,
                        "final_window_count": cache.cachedWindowCount + 1,
                        "cached_input_bytes": cache.totalInputByteCount,
                        "total_precompute_wall_ms": cache.totalPrecomputeWallMilliseconds,
                        "precompute_duty_percent": cache.totalPrecomputeWallMilliseconds
                            / (Double(samples.count) / Double(ASRConstants.sampleRate) * 1_000) * 100,
                        "windows": metadata,
                        "offline_raw_transcript_sha256": offlineTextSHA,
                        "offline_token_timings_sha256": offlineTimingSHA,
                        "cached_raw_transcript_sha256": cachedTextSHA,
                        "cached_token_timings_sha256": cachedTimingSHA,
                        "exact_offline_parity": true,
                        "peak_rss_bytes": peakRSSBytes(),
                    ]
                    preloadAudits[key] = preloadAudit
                    try jsonLine(
                        response(
                            id: id,
                            command: command,
                            fields: preloadAudit
                        )
                    )

                case "run":
                    guard let manager, loaded else {
                        throw NSError(
                            domain: "all-closed-jsonl-server",
                            code: 9,
                            userInfo: [NSLocalizedDescriptionKey: "load must complete first"]
                        )
                    }
                    let key = try string(request, "key")
                    guard let fixture = fixtures[key] else {
                        throw NSError(
                            domain: "all-closed-jsonl-server",
                            code: 10,
                            userInfo: [NSLocalizedDescriptionKey: "key was not preloaded"]
                        )
                    }
                    let requestedLanguage = request["language"] as? String
                    guard requestedLanguage == fixture.language?.rawValue else {
                        throw NSError(
                            domain: "all-closed-jsonl-server",
                            code: 11,
                            userInfo: [NSLocalizedDescriptionKey: "language differs from preload"]
                        )
                    }
                    let started = ContinuousClock.now
                    let result = try await manager.tempTranscribeUsingAllClosedChunks(
                        fixture.samples,
                        cache: fixture.cache,
                        language: fixture.language
                    )
                    let elapsed = nanoseconds(started.duration(to: .now))
                    let textSHA = sha256(Data(result.text.utf8))
                    let timingSHA = try stableHash(result.tokenTimings ?? [])
                    guard textSHA == fixture.offlineTextSHA256,
                        timingSHA == fixture.offlineTimingSHA256
                    else {
                        throw NSError(
                            domain: "all-closed-jsonl-server",
                            code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "OR cache parity mismatch during timed run"]
                        )
                    }
                    let runAudit: [String: Any] = [
                        "elapsed_ns": elapsed,
                        "pcm_f32le_sha256": fixture.pcmSHA256,
                        "raw_transcript_sha256": textSHA,
                        "normalized_transcript_sha256": normalizedHash(result.text),
                        "token_timings_sha256": timingSHA,
                        "exact_offline_parity": true,
                        "peak_rss_bytes": peakRSSBytes(),
                    ]
                    runAudits[key, default: []].append(runAudit)
                    try jsonLine(
                        response(
                            id: id,
                            command: command,
                            fields: [
                                "elapsed_ns": elapsed,
                                "sample_rate": ASRConstants.sampleRate,
                                "sample_count": fixture.samples.count,
                                "pcm_f32le_sha256": fixture.pcmSHA256,
                                "raw_transcript_sha256": textSHA,
                                "normalized_transcript_sha256": normalizedHash(result.text),
                                "token_timings_sha256": timingSHA,
                                "text": result.text,
                                "prewarmed": prewarmed,
                                "language_override": requestedLanguage ?? NSNull(),
                                "peak_rss_bytes": peakRSSBytes(),
                                "exact_offline_parity": true,
                                "timing": [
                                    "schema_version": 1,
                                    "clock": "monotonic_uptime",
                                    "total_wall_ns": elapsed,
                                    "total_wall_scope": "predecoded_transcribe",
                                    "phases_may_overlap": false,
                                    "phases": [
                                        "primary_tdt_inference_decode_ns": elapsed,
                                        "lexical_candidate_gate_ns": NSNull(),
                                        "ctc_model_inference_ns": NSNull(),
                                        "ctc_rescoring_fusion_ns": NSNull(),
                                    ],
                                    "ctc_inference_invocations": 0,
                                    "vocabulary_outcome": "not_configured",
                                ],
                            ]
                        )
                    )

                case "shutdown":
                    if let auditPath {
                        let audit: [String: Any] = [
                            "schema_version": 1,
                            "protocol_shutdown": true,
                            "application_head": "f2b6e8cc66d20f7a07094f79af0faf3ba861af64",
                            "fluid_audio_base_revision": "ee9a7f12d91710da53de6d75f8b7160e09eccee4",
                            "load": loadAudit,
                            "preloads": preloadAudits,
                            "runs": runAudits,
                            "peak_rss_bytes": peakRSSBytes(),
                        ]
                        let data = try JSONSerialization.data(
                            withJSONObject: audit,
                            options: [.prettyPrinted, .sortedKeys]
                        )
                        try data.write(to: URL(fileURLWithPath: auditPath), options: .atomic)
                    }
                    try jsonLine(response(id: id, command: command))
                    return

                default:
                    throw NSError(
                        domain: "all-closed-jsonl-server",
                        code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "unknown command: \(command)"]
                    )
                }
            } catch {
                try jsonLine(errorResponse(id: id, detail: error.localizedDescription))
                if (error as NSError).code == 42 { throw error }
            }
        }
    }
}
