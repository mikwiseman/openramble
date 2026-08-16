import CryptoKit
import Darwin
import FluidAudio
import Foundation

private let protocolVersion = 1
private let sampleRate = 16_000
private let minimumModelSamples = 3_200
private let maximumModelSamples = 480_000
private let expectedArtifactManifestSHA256 =
    "d0a99130a53b09b6756b1203eb057d197608f278913f7aace3ce1a71b00e7906"

private struct ArtifactManifest: Decodable {
    struct Artifact: Decodable {
        let path: String
        let byteCount: Int64
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case path
            case byteCount = "byte_count"
            case sha256
        }
    }

    let repository: String
    let revision: String
    let precision: String
    let computeUnits: String
    let artifacts: [Artifact]

    enum CodingKeys: String, CodingKey {
        case repository
        case revision
        case precision
        case computeUnits = "compute_units"
        case artifacts
    }
}

private struct PreloadedPCM {
    let samples: [Float]
    let sha256: String
}

private final class ServerState {
    var models: SenseVoiceModels?
    var managers: [String: SenseVoiceManager] = [:]
    var preloaded: [String: PreloadedPCM] = [:]
    var didPrewarm = false
    let modelDirectory: URL
    let artifactManifest: ArtifactManifest
    let artifactManifestSHA256: String

    init(
        modelDirectory: URL,
        artifactManifest: ArtifactManifest,
        artifactManifestSHA256: String
    ) {
        self.modelDirectory = modelDirectory
        self.artifactManifest = artifactManifest
        self.artifactManifestSHA256 = artifactManifestSHA256
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case usage(String)
    case token(String)
    case manifest(String)
    case invalidRequest(String)
    case invalidState(String)
    case invalidPCM(String)

    var description: String {
        switch self {
        case .usage(let detail): "usage: \(detail)"
        case .token(let detail): "one-use authorization rejected: \(detail)"
        case .manifest(let detail): "artifact manifest rejected: \(detail)"
        case .invalidRequest(let detail): "invalid request: \(detail)"
        case .invalidState(let detail): "invalid state: \(detail)"
        case .invalidPCM(let detail): "invalid PCM: \(detail)"
        }
    }
}

@main
private struct SenseVoiceProbe {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.first == "server" else {
                throw ProbeError.usage(
                    "sensevoice-probe server --model-dir DIR --artifact-manifest FILE "
                        + "--token-file FILE --token-sha256 HEX"
                )
            }
            let options = try parseOptions(Array(arguments.dropFirst()))
            let modelDirectory = try requiredURL("model-dir", in: options)
            let manifestURL = try requiredURL("artifact-manifest", in: options)
            let tokenURL = try requiredURL("token-file", in: options)
            guard let expectedTokenSHA = options["token-sha256"] else {
                throw ProbeError.usage("missing --token-sha256")
            }

            // Authorization is deliberately consumed before Core ML can be touched.
            // The token bytes are never logged or placed in output metadata.
            try consumeOneUseToken(at: tokenURL, expectedSHA256: expectedTokenSHA)

            let manifestData = try Data(contentsOf: manifestURL)
            guard sha256(manifestData) == expectedArtifactManifestSHA256 else {
                throw ProbeError.manifest("artifact manifest SHA-256 does not match the sealed probe")
            }
            let manifest = try JSONDecoder().decode(ArtifactManifest.self, from: manifestData)
            try validateManifest(manifest, modelDirectory: modelDirectory)

            // Every production-capable download entry point fails closed from here on.
            // This probe only uses SenseVoiceModels.load(from:), never .load() or
            // .downloadAndLoad().
            ModelHub.offlineMode = true
            ModelRegistry.baseURL = "http://127.0.0.1:9"

            let state = ServerState(
                modelDirectory: modelDirectory,
                artifactManifest: manifest,
                artifactManifestSHA256: sha256(manifestData)
            )
            let code = await runServer(state: state)
            exit(code)
        } catch {
            writeError("fatal: \(error)")
            exit(64)
        }
    }
}

private func runServer(state: ServerState) async -> Int32 {
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            guard let request = object as? [String: Any] else {
                throw ProbeError.invalidRequest("request must be a JSON object")
            }
            let requestID = request["id"] ?? NSNull()
            if try await handle(request, requestID: requestID, state: state) { return 0 }
        } catch {
            emit([
                "id": requestIdentifier(from: line),
                "ok": false,
                "protocol_version": protocolVersion,
                "error": String(describing: error),
            ])
        }
    }
    return 0
}

private func handle(
    _ request: [String: Any],
    requestID: Any,
    state: ServerState
) async throws -> Bool {
    guard let command = request["command"] as? String else {
        throw ProbeError.invalidRequest("missing string field 'command'")
    }

    switch command {
    case "load":
        guard state.models == nil else {
            throw ProbeError.invalidState("model is already loaded")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let models = try SenseVoiceModels.load(from: state.modelDirectory, precision: .int8)
        state.models = models
        state.managers = [
            "auto": SenseVoiceManager(models: models, language: SenseVoiceConfig.defaultLanguage),
            "en": SenseVoiceManager(models: models, language: 4),
        ]
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        emit([
            "id": requestID,
            "ok": true,
            "protocol_version": protocolVersion,
            "command": command,
            "load_ns": NSNumber(value: elapsed),
            "model": modelIdentity(state),
            "peak_rss_bytes": NSNumber(value: peakMemoryBytes()),
        ])

    case "prewarm":
        let manager = try loadedManager("auto", state: state)
        let started = DispatchTime.now().uptimeNanoseconds
        _ = try await manager.transcribe(audio: [Float](repeating: 0, count: sampleRate))
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        state.didPrewarm = true
        emit([
            "id": requestID,
            "ok": true,
            "protocol_version": protocolVersion,
            "command": command,
            "prewarm_ns": NSNumber(value: elapsed),
            "peak_rss_bytes": NSNumber(value: peakMemoryBytes()),
        ])

    case "preload":
        guard let key = request["key"] as? String, !key.isEmpty,
              let inputPath = request["path"] as? String, !inputPath.isEmpty,
              let expectedSourceSHA256 = request["source_sha256"] as? String,
              let expectedSampleCount = request["sample_count"] as? Int
        else {
            throw ProbeError.invalidRequest(
                "preload requires non-empty 'key'/'path', 'source_sha256', and integer 'sample_count'"
            )
        }
        guard expectedSourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              expectedSampleCount > 0
        else {
            throw ProbeError.invalidRequest("invalid preload source identity")
        }
        let inputURL = URL(fileURLWithPath: inputPath)
        let observedSourceSHA256 = try sha256File(inputURL)
        guard observedSourceSHA256 == expectedSourceSHA256 else {
            throw ProbeError.invalidPCM("source file SHA-256 mismatch")
        }
        let format = request["format"] as? String ?? "audio"
        let samples: [Float]
        switch format {
        case "audio":
            samples = try AudioConverter(sampleRate: Double(sampleRate))
                .resampleAudioFile(inputURL)
        case "f32le":
            samples = try decodeCanonicalPCM(at: inputURL)
        default:
            throw ProbeError.invalidRequest("unsupported preload format '\(format)'")
        }
        try validate(samples: samples)
        guard samples.count == expectedSampleCount else {
            throw ProbeError.invalidPCM(
                "sample count mismatch: expected \(expectedSampleCount), observed \(samples.count)"
            )
        }
        guard (minimumModelSamples...maximumModelSamples).contains(samples.count) else {
            throw ProbeError.invalidPCM(
                "sample count must be in the compiled preprocessor range "
                    + "\(minimumModelSamples)...\(maximumModelSamples)"
            )
        }
        let pcm = canonicalPCM(samples)
        state.preloaded[key] = PreloadedPCM(samples: samples, sha256: sha256(pcm))
        emit([
            "id": requestID,
            "ok": true,
            "protocol_version": protocolVersion,
            "command": command,
            "key": key,
            "format": format,
            "source_file_sha256": observedSourceSHA256,
            "sample_rate": sampleRate,
            "sample_count": samples.count,
            "audio_duration_ns": NSNumber(
                value: UInt64(samples.count) * 1_000_000_000 / UInt64(sampleRate)
            ),
            "pcm_f32le_sha256": sha256(pcm),
        ])

    case "run":
        guard let key = request["key"] as? String,
              let preloaded = state.preloaded[key]
        else {
            throw ProbeError.invalidRequest("run requires a preloaded 'key'")
        }
        guard (minimumModelSamples...maximumModelSamples).contains(preloaded.samples.count) else {
            throw ProbeError.invalidPCM(
                "sample count must be in the compiled preprocessor range "
                    + "\(minimumModelSamples)...\(maximumModelSamples)"
            )
        }
        let language = request["language"] as? String ?? "auto"
        guard language == "auto" || language == "en" else {
            throw ProbeError.invalidRequest(
                "SenseVoiceSmall exposes no supported '\(language)' hint; use auto only for diagnostic falsification"
            )
        }
        let manager = try loadedManager(language, state: state)
        let started = DispatchTime.now().uptimeNanoseconds
        let text = try await manager.transcribe(audio: preloaded.samples)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        emit([
            "id": requestID,
            "ok": true,
            "protocol_version": protocolVersion,
            "command": command,
            "elapsed_ns": NSNumber(value: elapsed),
            "sample_rate": sampleRate,
            "sample_count": preloaded.samples.count,
            "pcm_f32le_sha256": preloaded.sha256,
            "raw_transcript_sha256": sha256(Data(text.utf8)),
            "text": text,
            "requested_language": language,
            "effective_language_embed_index": language == "en" ? 4 : 0,
            "detected_language": NSNull(),
            "token_timings": NSNull(),
            "word_timings": NSNull(),
            "confidence": NSNull(),
            "vocabulary_candidate_regions": NSNull(),
            "prewarmed": state.didPrewarm,
            "peak_rss_bytes": NSNumber(value: peakMemoryBytes()),
        ])

    case "shutdown":
        state.preloaded.removeAll(keepingCapacity: false)
        state.managers.removeAll(keepingCapacity: false)
        state.models = nil
        emit([
            "id": requestID,
            "ok": true,
            "protocol_version": protocolVersion,
            "command": command,
        ])
        return true

    default:
        throw ProbeError.invalidRequest("unknown command '\(command)'")
    }
    return false
}

private func loadedManager(_ language: String, state: ServerState) throws -> SenseVoiceManager {
    guard state.models != nil, let manager = state.managers[language] else {
        throw ProbeError.invalidState("load must complete first")
    }
    return manager
}

private func modelIdentity(_ state: ServerState) -> [String: Any] {
    [
        "repository": state.artifactManifest.repository,
        "revision": state.artifactManifest.revision,
        "precision": state.artifactManifest.precision,
        "compute_units": state.artifactManifest.computeUnits,
        "artifact_manifest_sha256": state.artifactManifestSHA256,
        "model_directory": state.modelDirectory.path,
        "artifacts": state.artifactManifest.artifacts.map {
            ["path": $0.path, "byte_count": $0.byteCount, "sha256": $0.sha256]
        },
        "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        "process_arch": "arm64",
    ]
}

private func parseOptions(_ arguments: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        guard flag.hasPrefix("--"), index + 1 < arguments.count else {
            throw ProbeError.usage("expected --name value pairs")
        }
        let key = String(flag.dropFirst(2))
        guard result[key] == nil else { throw ProbeError.usage("duplicate --\(key)") }
        result[key] = arguments[index + 1]
        index += 2
    }
    return result
}

private func requiredURL(_ name: String, in options: [String: String]) throws -> URL {
    guard let value = options[name], !value.isEmpty else {
        throw ProbeError.usage("missing --\(name)")
    }
    return URL(fileURLWithPath: value)
}

private func consumeOneUseToken(at url: URL, expectedSHA256: String) throws {
    guard expectedSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw ProbeError.token("expected SHA-256 must be 64 lowercase hex characters")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber,
          permissions.intValue & 0o777 == 0o600
    else {
        throw ProbeError.token("token file mode must be 0600")
    }
    let data = try Data(contentsOf: url)
    guard !data.isEmpty, data.count <= 4096 else {
        throw ProbeError.token("token file must contain 1...4096 bytes")
    }
    guard sha256(data) == expectedSHA256 else {
        throw ProbeError.token("token SHA-256 mismatch")
    }
    try FileManager.default.removeItem(at: url)
}

private func validateManifest(_ manifest: ArtifactManifest, modelDirectory: URL) throws {
    guard manifest.repository == "FluidInference/sensevoice-small-coreml" else {
        throw ProbeError.manifest("unexpected repository")
    }
    guard manifest.revision == "cdea3526163035c19915d4a10268992d018ebd46" else {
        throw ProbeError.manifest("unexpected model revision")
    }
    guard manifest.precision == "int8", manifest.computeUnits == "cpuAndNeuralEngine" else {
        throw ProbeError.manifest("only the preregistered int8 CPU+ANE route is allowed")
    }
    guard manifest.artifacts.count == 9 else {
        throw ProbeError.manifest("expected exactly 9 artifacts")
    }

    let root = modelDirectory.standardizedFileURL.path
    var seen = Set<String>()
    for artifact in manifest.artifacts {
        guard !artifact.path.hasPrefix("/"), !artifact.path.split(separator: "/").contains("..") else {
            throw ProbeError.manifest("unsafe path \(artifact.path)")
        }
        guard seen.insert(artifact.path).inserted else {
            throw ProbeError.manifest("duplicate path \(artifact.path)")
        }
        let url = modelDirectory.appendingPathComponent(artifact.path).standardizedFileURL
        guard url.path.hasPrefix(root + "/") else {
            throw ProbeError.manifest("path escapes model directory: \(artifact.path)")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProbeError.manifest("artifact is missing: \(artifact.path)")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ProbeError.manifest("artifact is missing, non-regular, or a symlink: \(artifact.path)")
        }
        guard Int64(values.fileSize ?? -1) == artifact.byteCount else {
            throw ProbeError.manifest("size mismatch: \(artifact.path)")
        }
        guard try sha256File(url) == artifact.sha256 else {
            throw ProbeError.manifest("SHA-256 mismatch: \(artifact.path)")
        }
    }
}

private func sha256File(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func decodeCanonicalPCM(at url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
        throw ProbeError.invalidPCM("f32le PCM must contain complete Float32 values")
    }
    return data.withUnsafeBytes { raw in
        stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size).map { offset in
            let word = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return Float(bitPattern: UInt32(littleEndian: word))
        }
    }
}

private func validate(samples: [Float]) throws {
    guard !samples.isEmpty else { throw ProbeError.invalidPCM("PCM is empty") }
    guard samples.allSatisfy(\.isFinite) else {
        throw ProbeError.invalidPCM("PCM contains NaN or infinity")
    }
}

private func canonicalPCM(_ samples: [Float]) -> Data {
    let words = samples.map { $0.bitPattern.littleEndian }
    return words.withUnsafeBytes { Data($0) }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func peakMemoryBytes() -> Int64 {
    var info = rusage()
    guard getrusage(RUSAGE_SELF, &info) == 0 else { return -1 }
    return Int64(info.ru_maxrss)
}

private func requestIdentifier(from line: String) -> Any {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return NSNull() }
    return object["id"] ?? NSNull()
}

private func emit(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8)
    else {
        writeError("fatal: response encoding failed")
        return
    }
    print(line)
    fflush(stdout)
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
