import CryptoKit
import Foundation
import LocalASR

/// A deliberately small, line-delimited protocol for latency experiments.
///
/// The process owns one model instance for its whole lifetime. Audio is decoded
/// before the measured lane and kept as 16 kHz mono Float32. This prevents model
/// load, process launch, WAV decoding, and IPC from leaking into the inference
/// timer. `run-file` exists as a separately named diagnostic lane.
enum BenchmarkJSONLServer {
    static let protocolVersion = 1
    static let sampleRate = 16_000

    private final class State {
        var transcriber: LocalTranscriber?
        var preloaded: [String: PreloadedPCM] = [:]
        var didPrewarm = false
    }

    private struct PreloadedPCM {
        let samples: [Float]
        let sha256: String
    }

    static func run() async -> Int32 {
        let state = State()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let requestID: Any
            do {
                let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
                guard let request = value as? [String: Any] else {
                    throw ProtocolError.invalidRequest("request must be a JSON object")
                }
                requestID = request["id"] ?? NSNull()
                let shouldStop = try await handle(request, state: state, requestID: requestID)
                if shouldStop { return 0 }
            } catch {
                emit([
                    "id": (try? requestIdentifier(from: line)) ?? NSNull(),
                    "ok": false,
                    "protocol_version": protocolVersion,
                    "error": String(describing: error),
                ])
            }
        }
        return 0
    }

    private static func handle(
        _ request: [String: Any],
        state: State,
        requestID: Any
    ) async throws -> Bool {
        guard let command = request["command"] as? String else {
            throw ProtocolError.invalidRequest("missing string field 'command'")
        }

        switch command {
        case "load":
            guard state.transcriber == nil else {
                throw ProtocolError.invalidState("model is already loaded")
            }
            let started = DispatchTime.now().uptimeNanoseconds
            state.transcriber = try await prepareTranscriber(
                performConfiguredWarmup: false,
                logger: log
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            emit([
                "id": requestID,
                "ok": true,
                "protocol_version": protocolVersion,
                "command": command,
                "load_ns": NSNumber(value: elapsed),
                "effective_settings": effectiveSettings(),
                "model": try modelIdentity(vocabulary: false),
                "vocabulary_model": try optionalVocabularyIdentity(),
            ])

        case "prewarm":
            let transcriber = try loadedTranscriber(state)
            let started = DispatchTime.now().uptimeNanoseconds
            try await transcriber.warmUpInference()
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            state.didPrewarm = true
            emit([
                "id": requestID,
                "ok": true,
                "protocol_version": protocolVersion,
                "command": command,
                "prewarm_ns": NSNumber(value: elapsed),
            ])

        case "preload":
            _ = try loadedTranscriber(state)
            guard let key = request["key"] as? String, !key.isEmpty,
                  let path = request["path"] as? String, !path.isEmpty
            else {
                throw ProtocolError.invalidRequest("preload requires non-empty 'key' and 'path'")
            }
            let format = request["format"] as? String ?? "audio"
            let samples: [Float]
            switch format {
            case "audio":
                samples = try AudioFileReader().samples(from: URL(fileURLWithPath: path))
            case "f32le":
                samples = try decodeCanonicalPCM(at: URL(fileURLWithPath: path))
            default:
                throw ProtocolError.invalidRequest("unsupported preload format '\(format)'")
            }
            try validate(samples: samples)
            let pcm = canonicalPCM(samples)
            if let exportPath = request["canonical_path"] as? String, !exportPath.isEmpty {
                let url = URL(fileURLWithPath: exportPath)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try pcm.write(to: url, options: .atomic)
                _ = chmod(url.path, S_IRUSR | S_IWUSR)
            }
            let pcmHash = sha256(pcm)
            state.preloaded[key] = PreloadedPCM(samples: samples, sha256: pcmHash)
            emit([
                "id": requestID,
                "ok": true,
                "protocol_version": protocolVersion,
                "command": command,
                "key": key,
                "format": format,
                "sample_rate": sampleRate,
                "sample_count": samples.count,
                "audio_duration_ns": NSNumber(
                    value: UInt64(samples.count) * 1_000_000_000 / UInt64(sampleRate)
                ),
                "pcm_f32le_sha256": pcmHash,
            ])

        case "run":
            let transcriber = try loadedTranscriber(state)
            guard let key = request["key"] as? String,
                  let preloaded = state.preloaded[key]
            else {
                throw ProtocolError.invalidRequest("run requires a preloaded 'key'")
            }
            let language = (request["language"] as? String)
                ?? ProcessInfo.processInfo.environment["WAI_ASR_LANGUAGE"]
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try await transcriber.transcribe(
                samples: preloaded.samples,
                languageHint: language
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            emit(runResponse(
                requestID: requestID,
                command: command,
                elapsed: elapsed,
                result: result.text,
                pcmHash: preloaded.sha256,
                sampleCount: preloaded.samples.count,
                didPrewarm: state.didPrewarm
            ))

        case "run-file":
            let transcriber = try loadedTranscriber(state)
            guard let path = request["path"] as? String, !path.isEmpty else {
                throw ProtocolError.invalidRequest("run-file requires non-empty 'path'")
            }
            let language = (request["language"] as? String)
                ?? ProcessInfo.processInfo.environment["WAI_ASR_LANGUAGE"]
            let started = DispatchTime.now().uptimeNanoseconds
            let samples = try AudioFileReader().samples(from: URL(fileURLWithPath: path))
            try validate(samples: samples)
            let result = try await transcriber.transcribe(samples: samples, languageHint: language)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            emit(runResponse(
                requestID: requestID,
                command: command,
                elapsed: elapsed,
                result: result.text,
                pcmHash: sha256(canonicalPCM(samples)),
                sampleCount: samples.count,
                didPrewarm: state.didPrewarm
            ))

        case "shutdown":
            emit([
                "id": requestID,
                "ok": true,
                "protocol_version": protocolVersion,
                "command": command,
            ])
            return true

        default:
            throw ProtocolError.invalidRequest("unknown command '\(command)'")
        }
        return false
    }

    private static func loadedTranscriber(_ state: State) throws -> LocalTranscriber {
        guard let transcriber = state.transcriber else {
            throw ProtocolError.invalidState("load must complete first")
        }
        return transcriber
    }

    private static func runResponse(
        requestID: Any,
        command: String,
        elapsed: UInt64,
        result: String,
        pcmHash: String,
        sampleCount: Int,
        didPrewarm: Bool
    ) -> [String: Any] {
        let normalized = TextNormalizer.normalize(result).text
        return [
            "id": requestID,
            "ok": true,
            "protocol_version": protocolVersion,
            "command": command,
            "elapsed_ns": NSNumber(value: elapsed),
            "sample_rate": sampleRate,
            "sample_count": sampleCount,
            "pcm_f32le_sha256": pcmHash,
            "raw_transcript_sha256": sha256(Data(result.utf8)),
            "normalized_transcript_sha256": sha256(Data(normalized.utf8)),
            // The orchestrator removes transcript text from the persisted report.
            // It needs the text transiently for a common cross-engine normalizer
            // and optional WER against the frozen reference.
            "text": result,
            "prewarmed": didPrewarm,
            "peak_rss_bytes": NSNumber(value: peakMemoryBytes()),
        ]
    }

    static func canonicalPCM(_ samples: [Float]) -> Data {
        let words = samples.map { $0.bitPattern.littleEndian }
        return words.withUnsafeBytes { Data($0) }
    }

    static func decodeCanonicalPCM(at url: URL) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw ProtocolError.invalidPCM("f32le PCM must contain one or more complete Float32 values")
        }
        return data.withUnsafeBytes { raw in
            stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size).map { offset in
                let little = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: little))
            }
        }
    }

    static func validate(samples: [Float]) throws {
        guard !samples.isEmpty else { throw ProtocolError.invalidPCM("PCM is empty") }
        guard samples.allSatisfy(\.isFinite) else {
            throw ProtocolError.invalidPCM("PCM contains NaN or infinity")
        }
    }

    private static func effectiveSettings() -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let defaults = VocabularyBoost.developerDefault()
        let vocabularyEnabled = isOn("WAI_VOCAB") || environment["WAI_VOCAB_DIR"] != nil
        return [
            "encoder": environment["WAI_ASR_ENCODER"] ?? EncoderVariant.palettized6bit.rawValue,
            "encoder_placement": environment["WAI_ASR_ENCODER_PLACEMENT"]
                ?? EncoderPlacement.automatic.rawValue,
            "mel_chunk_context": isOn("WAI_ASR_MEL_CONTEXT"),
            "dual_decode": isOn("WAI_ASR_DUAL_DECODE"),
            "max_tokens_per_chunk": Int(environment["WAI_ASR_MAX_TOKENS"] ?? "")
                ?? FluidAudioAdapter.defaultMaxTokensPerChunk,
            "parallel_chunk_concurrency": Int(environment["WAI_ASR_CHUNK_CONCURRENCY"] ?? "")
                ?? FluidAudioAdapter.defaultParallelChunkConcurrency,
            "vocabulary_enabled": vocabularyEnabled,
            "vocabulary_scheduling": environment["WAI_ASR_VOCAB_SCHEDULING"]
                ?? VocabularyInferenceScheduling.candidateRegions.rawValue,
            "vocabulary_terms": vocabularyEnabled
                ? (Int(environment["WAI_VOCAB_TERMS"] ?? "") ?? defaults.terms.count)
                : 0,
            "vocabulary_similarity": Double(environment["WAI_VOCAB_SIMILARITY"] ?? "")
                ?? Double(defaults.minSimilarity),
            "vocabulary_bias_weight": Double(environment["WAI_VOCAB_CBW"] ?? "")
                ?? Double(defaults.biasWeight),
            "language": environment["WAI_ASR_LANGUAGE"] ?? NSNull(),
        ]
    }

    private static func modelIdentity(vocabulary: Bool) throws -> [String: Any] {
        let manifest = try vocabulary ? ModelManifest.bundledVocabulary() : ModelManifest.bundled()
        let explicitKey = vocabulary ? "WAI_VOCAB_DIR" : "WAI_ASR_MODEL_DIR"
        let directory: URL
        if let path = ProcessInfo.processInfo.environment[explicitKey] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let layout = try ModelInstallLayout(manifest: manifest, root: modelsRoot())
            directory = layout.engineDirectory
        }
        let encoded = try JSONEncoder.sorted.encode(manifest)
        return [
            "model_id": manifest.modelID,
            "repository": manifest.repository,
            "revision": manifest.revision,
            "fluid_audio_version": manifest.fluidAudioVersion,
            "quantization": manifest.quantization,
            "license": manifest.license,
            "manifest_sha256": sha256(encoded),
            "engine_directory": directory.path,
            "files": manifest.files.map {
                ["path": $0.path, "byte_count": $0.byteCount, "sha256": $0.sha256]
            },
        ]
    }

    private static func optionalVocabularyIdentity() throws -> Any {
        let environment = ProcessInfo.processInfo.environment
        guard isOn("WAI_VOCAB") || environment["WAI_VOCAB_DIR"] != nil else {
            return NSNull()
        }
        return try modelIdentity(vocabulary: true)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func requestIdentifier(from line: String) throws -> Any {
        let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return (value as? [String: Any])?["id"] ?? NSNull()
    }

    private static func emit(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else {
            log("fatal: could not encode benchmark response")
            return
        }
        print(line)
        fflush(stdout)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    enum ProtocolError: Error, CustomStringConvertible {
        case invalidRequest(String)
        case invalidState(String)
        case invalidPCM(String)

        var description: String {
            switch self {
            case let .invalidRequest(detail): "invalid request: \(detail)"
            case let .invalidState(detail): "invalid state: \(detail)"
            case let .invalidPCM(detail): "invalid PCM: \(detail)"
            }
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
