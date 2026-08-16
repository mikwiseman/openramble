import CoreML
import CryptoKit
import Darwin
import Foundation
import FluidAudio

private struct Manifest: Decodable {
    let fixtures: [Fixture]
}

private struct Fixture: Decodable {
    let id: String
    let path: String
    let language: String?
    let kind: String?
    let sha256: String?
    let reference: String?
}

private struct ChunkPolicy: Encodable {
    let modelMaximumSamples: Int
    let modelMaximumSeconds: Double
    let chunkSamples: Int
    let chunkSeconds: Double
    let overlapSamples: Int
    let overlapSeconds: Double
    let strideSamples: Int
    let strideSeconds: Double
    let melContextSamples: Int
    let melContextSeconds: Double
    let parallelChunkConcurrency: Int
    let maxTokensPerChunk: Int
    let melChunkContext: Bool
    let dualDecodeArbitration: Bool
    let mergePolicy: String
}

private struct FixtureResult: Encodable {
    let id: String
    let kind: String?
    let path: String
    let sourceSHA256: String?
    let language: String?
    let reference: String?
    let sampleCount: Int
    let audioDurationSeconds: Double
    let firstMeasuredTranscript: String
    let firstMeasuredNormalizedTranscript: String
    let firstMeasuredTranscriptSHA256: String
    let firstMeasuredNormalizedTranscriptSHA256: String
    let transcriptStable: Bool
    let normalizedTranscriptStable: Bool
    let transcriptVariants: [String]
    let normalizedTranscriptVariants: [String]
    let firstTokenTimings: [TokenTiming]
    let firstWordTimings: [WordTiming]
    let firstTokenTimingsSHA256: String
    let firstWordTimingsSHA256: String
    let tokenTimingsStable: Bool
    let wordTimingsStable: Bool
    let tokenTimingHashVariants: [String]
    let wordTimingHashVariants: [String]
    let encoderWindowCounts: [Int]
    let encoderWindowCountStable: Bool
    let firstWindowLayouts: [TempASRWindowLayout]
    let windowLayoutStable: Bool
    let windowLayoutHashVariants: [String]
    let elapsedNanoseconds: [UInt64]
    let peakRSSBeforeFixtureBytes: UInt64
    let peakRSSAfterFixtureBytes: UInt64
}

private struct Report: Encodable {
    let schemaVersion: Int
    let modelDirectory: String
    let modelWindowSeconds: Double
    let computeUnits: String
    let warmupCountPerFixture: Int
    let repeatCount: Int
    let chunkPolicy: ChunkPolicy
    let peakRSSAtStartBytes: UInt64
    let peakRSSAfterModelsLoadBytes: UInt64
    let peakRSSAfterManagerLoadBytes: UInt64
    let peakRSSAfterFirstInferenceBytes: UInt64
    let peakRSSAtEndBytes: UInt64
    let modelsLoadNanoseconds: UInt64
    let managerLoadNanoseconds: UInt64
    let firstInferenceNanoseconds: UInt64
    let firstInferenceFixtureID: String
    let firstInferenceTranscript: String
    let firstInferenceNormalizedTranscript: String
    let firstInferenceEncoderWindowCount: Int
    let fixtures: [FixtureResult]
}

private struct Arguments {
    let modelDirectory: String
    let manifestPath: String
    let warmupCount: Int
    let repeatCount: Int
    let modelWindowSeconds: Double
    let reportPath: String

    init(_ values: [String]) throws {
        guard values.count == 6,
            let warmups = Int(values[2]), warmups >= 0,
            let repeats = Int(values[3]), repeats > 0,
            let seconds = Double(values[4]), seconds > 0
        else {
            throw NSError(
                domain: "short-shape-bench",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "usage: short-shape-bench MODEL_DIR MANIFEST WARMUPS REPEATS WINDOW_SECONDS REPORT_PATH"
                ]
            )
        }
        modelDirectory = values[0]
        manifestPath = values[1]
        warmupCount = warmups
        repeatCount = repeats
        modelWindowSeconds = seconds
        reportPath = values[5]
    }
}

@inline(__always)
private func now() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func peakRSSBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    // macOS reports ru_maxrss in bytes (Linux reports KiB).
    return UInt64(max(0, usage.ru_maxrss))
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256(_ text: String) -> String {
    sha256(Data(text.utf8))
}

private func stableHash<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256(try encoder.encode(value))
}

private func normalize(_ text: String) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    let pieces = folded.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
    }
    return String(pieces).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func makeChunkPolicy(modelWindowSeconds: Double) -> ChunkPolicy {
    let sampleRate = ASRConstants.sampleRate
    let modelMaximumSamples = Int((Double(sampleRate) * modelWindowSeconds).rounded())
    let frameSamples = ASRConstants.samplesPerEncoderFrame
    let melContextSamples = 0
    let rawChunkSamples = max(
        modelMaximumSamples - melContextSamples - ASRConstants.melHopSize,
        frameSamples
    )
    let chunkSamples = rawChunkSamples / frameSamples * frameSamples
    let requestedOverlap = Int(2.0 * Double(sampleRate))
    let overlapSamples = min(requestedOverlap, chunkSamples / 2) / frameSamples * frameSamples
    let strideSamples = max(chunkSamples - overlapSamples, frameSamples) / frameSamples * frameSamples
    return ChunkPolicy(
        modelMaximumSamples: modelMaximumSamples,
        modelMaximumSeconds: Double(modelMaximumSamples) / Double(sampleRate),
        chunkSamples: chunkSamples,
        chunkSeconds: Double(chunkSamples) / Double(sampleRate),
        overlapSamples: overlapSamples,
        overlapSeconds: Double(overlapSamples) / Double(sampleRate),
        strideSamples: strideSamples,
        strideSeconds: Double(strideSamples) / Double(sampleRate),
        melContextSamples: melContextSamples,
        melContextSeconds: Double(melContextSamples) / Double(sampleRate),
        parallelChunkConcurrency: 4,
        maxTokensPerChunk: 600,
        melChunkContext: false,
        dualDecodeArbitration: false,
        mergePolicy: "current v3 no-mel silence-aligned starts + ChunkProcessor.mergeChunks + timestamp sort + collapseSeamWordDuplicates; unchanged"
    )
}

@main
private enum ShortShapeBench {
    static func main() async throws {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENRAMBLE_TEMP_MODEL_WINDOW_SECONDS"] == String(arguments.modelWindowSeconds) else {
            throw NSError(
                domain: "short-shape-bench",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "OPENRAMBLE_TEMP_MODEL_WINDOW_SECONDS must exactly match WINDOW_SECONDS"
                ]
            )
        }
        guard environment["OPENRAMBLE_TEMP_WINDOW_DIAGNOSTICS"] == "1" else {
            throw NSError(
                domain: "short-shape-bench",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "OPENRAMBLE_TEMP_WINDOW_DIAGNOSTICS=1 is required"]
            )
        }

        let peakRSSAtStartBytes = peakRSSBytes()
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: arguments.manifestPath))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let fixtures = manifest.fixtures
        guard let firstFixture = fixtures.first else {
            throw NSError(
                domain: "short-shape-bench",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "manifest has no fixtures"]
            )
        }

        let converter = AudioConverter()
        var samplesByID: [String: [Float]] = [:]
        for fixture in fixtures {
            samplesByID[fixture.id] = try converter.resampleAudioFile(path: fixture.path)
        }

        ModelHub.offlineMode = true
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let modelsStart = now()
        let models = try await AsrModels.load(
            from: URL(fileURLWithPath: arguments.modelDirectory, isDirectory: true),
            configuration: configuration,
            version: .v3,
            encoderPrecision: .int8,
            encoderComputeUnits: .all
        )
        let modelsLoadNanoseconds = now() - modelsStart
        let peakRSSAfterModelsLoadBytes = peakRSSBytes()

        let manager = AsrManager(
            config: ASRConfig(
                tdtConfig: TdtConfig(maxTokensPerChunk: 600),
                parallelChunkConcurrency: 4,
                melChunkContext: false,
                dualDecodeArbitration: false
            )
        )
        let managerStart = now()
        try await manager.loadModels(models)
        let managerLoadNanoseconds = now() - managerStart
        let peakRSSAfterManagerLoadBytes = peakRSSBytes()

        guard let firstSamples = samplesByID[firstFixture.id] else {
            throw NSError(domain: "short-shape-bench", code: 6)
        }
        await resetTempASREncoderWindowCount()
        var firstState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let firstStart = now()
        let firstResult = try await manager.transcribe(
            firstSamples,
            decoderState: &firstState,
            language: firstFixture.language.flatMap(Language.init(rawValue:))
        )
        let firstInferenceNanoseconds = now() - firstStart
        let firstInferenceEncoderWindowCount = await tempASREncoderWindowCount()
        let peakRSSAfterFirstInferenceBytes = peakRSSBytes()

        var fixtureReports: [FixtureResult] = []
        for fixture in fixtures {
            guard let samples = samplesByID[fixture.id] else { continue }
            let language = fixture.language.flatMap(Language.init(rawValue:))

            for _ in 0..<arguments.warmupCount {
                await resetTempASREncoderWindowCount()
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                _ = try await manager.transcribe(samples, decoderState: &state, language: language)
            }

            let peakRSSBeforeFixtureBytes = peakRSSBytes()
            var elapsed: [UInt64] = []
            var transcriptVariants: Set<String> = []
            var normalizedTranscriptVariants: Set<String> = []
            var tokenTimingHashVariants: Set<String> = []
            var wordTimingHashVariants: Set<String> = []
            var windowLayoutHashVariants: Set<String> = []
            var encoderWindowCounts: [Int] = []
            var firstMeasuredTranscript = ""
            var firstMeasuredNormalizedTranscript = ""
            var firstTokenTimings: [TokenTiming] = []
            var firstWordTimings: [WordTiming] = []
            var firstWindowLayouts: [TempASRWindowLayout] = []
            var firstTokenTimingsSHA256 = ""
            var firstWordTimingsSHA256 = ""

            for repetition in 0..<arguments.repeatCount {
                await resetTempASREncoderWindowCount()
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let started = now()
                let result = try await manager.transcribe(samples, decoderState: &state, language: language)
                elapsed.append(now() - started)
                encoderWindowCounts.append(await tempASREncoderWindowCount())
                let windowLayouts = await tempASRWindowLayouts()

                let normalizedTranscript = normalize(result.text)
                let tokenTimings = result.tokenTimings ?? []
                let wordTimings = buildWordTimings(from: tokenTimings)
                let tokenTimingHash = try stableHash(tokenTimings)
                let wordTimingHash = try stableHash(wordTimings)
                let windowLayoutHash = try stableHash(windowLayouts)
                transcriptVariants.insert(result.text)
                normalizedTranscriptVariants.insert(normalizedTranscript)
                tokenTimingHashVariants.insert(tokenTimingHash)
                wordTimingHashVariants.insert(wordTimingHash)
                windowLayoutHashVariants.insert(windowLayoutHash)

                if repetition == 0 {
                    firstMeasuredTranscript = result.text
                    firstMeasuredNormalizedTranscript = normalizedTranscript
                    firstTokenTimings = tokenTimings
                    firstWordTimings = wordTimings
                    firstWindowLayouts = windowLayouts
                    firstTokenTimingsSHA256 = tokenTimingHash
                    firstWordTimingsSHA256 = wordTimingHash
                }
            }

            let peakRSSAfterFixtureBytes = peakRSSBytes()
            fixtureReports.append(
                FixtureResult(
                    id: fixture.id,
                    kind: fixture.kind,
                    path: fixture.path,
                    sourceSHA256: fixture.sha256,
                    language: fixture.language,
                    reference: fixture.reference,
                    sampleCount: samples.count,
                    audioDurationSeconds: Double(samples.count) / 16_000.0,
                    firstMeasuredTranscript: firstMeasuredTranscript,
                    firstMeasuredNormalizedTranscript: firstMeasuredNormalizedTranscript,
                    firstMeasuredTranscriptSHA256: sha256(firstMeasuredTranscript),
                    firstMeasuredNormalizedTranscriptSHA256: sha256(firstMeasuredNormalizedTranscript),
                    transcriptStable: transcriptVariants.count == 1,
                    normalizedTranscriptStable: normalizedTranscriptVariants.count == 1,
                    transcriptVariants: transcriptVariants.sorted(),
                    normalizedTranscriptVariants: normalizedTranscriptVariants.sorted(),
                    firstTokenTimings: firstTokenTimings,
                    firstWordTimings: firstWordTimings,
                    firstTokenTimingsSHA256: firstTokenTimingsSHA256,
                    firstWordTimingsSHA256: firstWordTimingsSHA256,
                    tokenTimingsStable: tokenTimingHashVariants.count == 1,
                    wordTimingsStable: wordTimingHashVariants.count == 1,
                    tokenTimingHashVariants: tokenTimingHashVariants.sorted(),
                    wordTimingHashVariants: wordTimingHashVariants.sorted(),
                    encoderWindowCounts: encoderWindowCounts,
                    encoderWindowCountStable: Set(encoderWindowCounts).count == 1,
                    firstWindowLayouts: firstWindowLayouts,
                    windowLayoutStable: windowLayoutHashVariants.count == 1,
                    windowLayoutHashVariants: windowLayoutHashVariants.sorted(),
                    elapsedNanoseconds: elapsed,
                    peakRSSBeforeFixtureBytes: peakRSSBeforeFixtureBytes,
                    peakRSSAfterFixtureBytes: peakRSSAfterFixtureBytes
                )
            )
            FileHandle.standardError.write(
                Data("completed fixture=\(fixture.id) repeats=\(arguments.repeatCount)\n".utf8)
            )
        }

        let report = Report(
            schemaVersion: 2,
            modelDirectory: arguments.modelDirectory,
            modelWindowSeconds: arguments.modelWindowSeconds,
            computeUnits: "MLComputeUnits.all",
            warmupCountPerFixture: arguments.warmupCount,
            repeatCount: arguments.repeatCount,
            chunkPolicy: makeChunkPolicy(modelWindowSeconds: arguments.modelWindowSeconds),
            peakRSSAtStartBytes: peakRSSAtStartBytes,
            peakRSSAfterModelsLoadBytes: peakRSSAfterModelsLoadBytes,
            peakRSSAfterManagerLoadBytes: peakRSSAfterManagerLoadBytes,
            peakRSSAfterFirstInferenceBytes: peakRSSAfterFirstInferenceBytes,
            peakRSSAtEndBytes: peakRSSBytes(),
            modelsLoadNanoseconds: modelsLoadNanoseconds,
            managerLoadNanoseconds: managerLoadNanoseconds,
            firstInferenceNanoseconds: firstInferenceNanoseconds,
            firstInferenceFixtureID: firstFixture.id,
            firstInferenceTranscript: firstResult.text,
            firstInferenceNormalizedTranscript: normalize(firstResult.text),
            firstInferenceEncoderWindowCount: firstInferenceEncoderWindowCount,
            fixtures: fixtureReports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportData = try encoder.encode(report)
        try reportData.write(to: URL(fileURLWithPath: arguments.reportPath), options: .atomic)
        FileHandle.standardOutput.write(reportData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
