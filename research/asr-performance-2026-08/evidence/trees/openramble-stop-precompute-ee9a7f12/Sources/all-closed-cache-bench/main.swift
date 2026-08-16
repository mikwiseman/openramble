import CoreML
import CryptoKit
import Darwin
import Foundation
import FluidAudio

private struct SourceManifest: Decodable {
    let fixtures: [SourceFixture]
}

private struct SourceFixture: Decodable {
    let id: String
    let path: String
    let language: String?
    let sha256: String
}

private struct FixtureInput {
    let id: String
    let kind: String
    let sourcePath: String
    let sourceFileSHA256: String
    let language: String?
    let samples: [Float]
}

private struct WindowSchedule: Encodable {
    let index: Int
    let chunkStartSeconds: Double
    let inputEndSeconds: Double
    let stableStartPrefixSeconds: Double
    let earliestSafePrefixSeconds: Double
    let precomputeWallMilliseconds: Double
    let simulatedStartSeconds: Double
    let simulatedReadySeconds: Double
    let slackBeforeStopSeconds: Double
    let tokenCount: Int
    let inputByteCount: Int
}

private struct FixtureReport: Encodable {
    let id: String
    let kind: String
    let sourcePath: String
    let sourceFileSHA256: String
    let sampleDataSHA256: String
    let sampleCount: Int
    let durationSeconds: Double
    let language: String?
    let finalWindowCount: Int
    let cachedClosedWindowCount: Int
    let cachedInputBytes: Int
    let totalPrecomputeWallMilliseconds: Double
    let precomputeDutyPercentOfSpeech: Double
    let allClosedWindowsReadyBeforeStop: Bool
    let minimumReadySlackSeconds: Double
    let schedules: [WindowSchedule]
    let baselineWallMilliseconds: [Double]
    let cachedFinalWallMilliseconds: [Double]
    let baselineP50Milliseconds: Double
    let baselineP95Milliseconds: Double
    let cachedFinalP50Milliseconds: Double
    let cachedFinalP95Milliseconds: Double
    let p50StopLatencySpeedup: Double
    let baselineTranscript: String
    let cachedTranscript: String
    let baselineTranscriptHashes: [String]
    let cachedTranscriptHashes: [String]
    let baselineTimingHashes: [String]
    let cachedTimingHashes: [String]
    let baselineTranscriptStable: Bool
    let cachedTranscriptStable: Bool
    let baselineTimingsStable: Bool
    let cachedTimingsStable: Bool
    let transcriptExact: Bool
    let tokenTimingsExact: Bool
}

private struct Report: Encodable {
    let schemaVersion: Int
    let applicationHead: String
    let fluidAudioBaseRevision: String
    let prototypeDiffSHA256: String
    let modelDirectory: String
    let modelConfiguration: String
    let cachePolicy: String
    let repeatCount: Int
    let persistentProcess: Bool
    let modelLoadMilliseconds: Double
    let peakRSSBytes: UInt64
    let fixtures: [FixtureReport]
}

private struct Arguments {
    let modelDirectory: String
    let manifestPath: String
    let reportPath: String
    let repeats: Int
    let prototypeDiffSHA256: String

    init(_ values: [String]) throws {
        guard values.count == 5, let repeats = Int(values[3]), repeats > 0 else {
            throw NSError(
                domain: "all-closed-cache-bench",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "usage: all-closed-cache-bench MODEL_DIR MANIFEST REPORT REPEATS PROTOTYPE_DIFF_SHA256"
                ]
            )
        }
        modelDirectory = values[0]
        manifestPath = values[1]
        reportPath = values[2]
        self.repeats = repeats
        prototypeDiffSHA256 = values[4]
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func stableHash<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256(try encoder.encode(value))
}

private func sampleHash(_ samples: [Float]) -> String {
    samples.withUnsafeBufferPointer { sha256(Data(buffer: $0)) }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1e15
}

private func percentile(_ values: [Double], fraction: Double) -> Double {
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)
    return sorted[max(0, index)]
}

private func peakRSSBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
}

private func repeatedSamples(_ source: [Float], count: Int) -> [Float] {
    precondition(!source.isEmpty)
    var output: [Float] = []
    output.reserveCapacity(count)
    while output.count < count {
        output.append(contentsOf: source.prefix(count - output.count))
    }
    return output
}

private func buildInputs(
    manifest: SourceManifest,
    converter: AudioConverter
) throws -> [FixtureInput] {
    guard let base = manifest.fixtures.first(where: { $0.id == "boundary-en-repeat-15.1s" }),
        let productNames = manifest.fixtures.first(where: { $0.id == "real-en-product-names-56.104s" }),
        let wholeEarth = manifest.fixtures.first(where: { $0.id == "real-en-whole-earth-84.381s" })
    else {
        throw NSError(domain: "all-closed-cache-bench", code: 3)
    }
    let baseSamples = try converter.resampleAudioFile(path: base.path)
    let syntheticDurations = [60, 120, 300]
    let synthetic = syntheticDurations.map { seconds in
        FixtureInput(
            id: "synthetic-en-repeat-\(seconds)s",
            kind: "deterministic-cyclic-repeat-of-boundary-en-repeat-15.1s",
            sourcePath: base.path,
            sourceFileSHA256: base.sha256,
            language: base.language,
            samples: repeatedSamples(baseSamples, count: seconds * ASRConstants.sampleRate)
        )
    }
    let real = try [productNames, wholeEarth].map { source in
        FixtureInput(
            id: source.id,
            kind: "real-long",
            sourcePath: source.path,
            sourceFileSHA256: source.sha256,
            language: source.language,
            samples: try converter.resampleAudioFile(path: source.path)
        )
    }
    return real + synthetic
}

@main
private enum AllClosedCacheBench {
    static func main() async throws {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        let sourceManifest = try JSONDecoder().decode(
            SourceManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments.manifestPath))
        )
        let converter = AudioConverter()
        let fixtures = try buildInputs(manifest: sourceManifest, converter: converter)

        ModelHub.offlineMode = true
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let modelLoadStarted = ContinuousClock.now
        let models = try await AsrModels.load(
            from: URL(fileURLWithPath: arguments.modelDirectory, isDirectory: true),
            configuration: configuration,
            version: .v3,
            encoderPrecision: .int8,
            encoderComputeUnits: .all
        )
        let modelLoadMilliseconds = milliseconds(modelLoadStarted.duration(to: .now))
        let manager = AsrManager(
            config: ASRConfig(
                tdtConfig: TdtConfig(maxTokensPerChunk: 600),
                parallelChunkConcurrency: 4,
                melChunkContext: false,
                dualDecodeArbitration: false
            )
        )
        try await manager.loadModels(models)

        let warmup = fixtures[0]
        var warmupState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe(
            warmup.samples,
            decoderState: &warmupState,
            language: warmup.language.flatMap(Language.init(rawValue:))
        )

        var fixtureReports: [FixtureReport] = []
        for fixture in fixtures {
            let samples = fixture.samples
            let durationSeconds = Double(samples.count) / Double(ASRConstants.sampleRate)
            let language = fixture.language.flatMap(Language.init(rawValue:))
            let cache = try await manager.tempPrecomputeAllProvablyClosedChunks(
                samples,
                language: language
            )

            var priorReadySeconds = 0.0
            let schedules = cache.metadata.map { metadata -> WindowSchedule in
                let simulatedStart = max(metadata.earliestSafePrefixSeconds, priorReadySeconds)
                let simulatedReady = simulatedStart + metadata.precomputeWallMilliseconds / 1_000
                priorReadySeconds = simulatedReady
                return WindowSchedule(
                    index: metadata.index,
                    chunkStartSeconds: metadata.chunkStartSeconds,
                    inputEndSeconds: metadata.inputEndSeconds,
                    stableStartPrefixSeconds: metadata.stableStartPrefixSeconds,
                    earliestSafePrefixSeconds: metadata.earliestSafePrefixSeconds,
                    precomputeWallMilliseconds: metadata.precomputeWallMilliseconds,
                    simulatedStartSeconds: simulatedStart,
                    simulatedReadySeconds: simulatedReady,
                    slackBeforeStopSeconds: durationSeconds - simulatedReady,
                    tokenCount: metadata.tokenCount,
                    inputByteCount: metadata.inputByteCount
                )
            }

            var baselineWalls: [Double] = []
            var cachedWalls: [Double] = []
            var baselineTexts: [String] = []
            var cachedTexts: [String] = []
            var baselineTextHashes: [String] = []
            var cachedTextHashes: [String] = []
            var baselineTimingHashes: [String] = []
            var cachedTimingHashes: [String] = []
            for _ in 0..<arguments.repeats {
                var baselineState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let baselineStarted = ContinuousClock.now
                let baseline = try await manager.transcribe(
                    samples,
                    decoderState: &baselineState,
                    language: language
                )
                baselineWalls.append(milliseconds(baselineStarted.duration(to: .now)))
                baselineTexts.append(baseline.text)
                baselineTextHashes.append(sha256(Data(baseline.text.utf8)))
                baselineTimingHashes.append(try stableHash(baseline.tokenTimings ?? []))

                let cachedStarted = ContinuousClock.now
                let cached = try await manager.tempTranscribeUsingAllClosedChunks(
                    samples,
                    cache: cache,
                    language: language
                )
                cachedWalls.append(milliseconds(cachedStarted.duration(to: .now)))
                cachedTexts.append(cached.text)
                cachedTextHashes.append(sha256(Data(cached.text.utf8)))
                cachedTimingHashes.append(try stableHash(cached.tokenTimings ?? []))
            }

            let baselineTextSet = Set(baselineTextHashes)
            let cachedTextSet = Set(cachedTextHashes)
            let baselineTimingSet = Set(baselineTimingHashes)
            let cachedTimingSet = Set(cachedTimingHashes)
            let transcriptExact =
                baselineTextSet.count == 1
                && cachedTextSet.count == 1
                && baselineTextSet == cachedTextSet
            let timingsExact =
                baselineTimingSet.count == 1
                && cachedTimingSet.count == 1
                && baselineTimingSet == cachedTimingSet
            let baselineP50 = percentile(baselineWalls, fraction: 0.50)
            let cachedP50 = percentile(cachedWalls, fraction: 0.50)
            let minimumSlack = schedules.map(\.slackBeforeStopSeconds).min() ?? durationSeconds

            fixtureReports.append(
                FixtureReport(
                    id: fixture.id,
                    kind: fixture.kind,
                    sourcePath: fixture.sourcePath,
                    sourceFileSHA256: fixture.sourceFileSHA256,
                    sampleDataSHA256: sampleHash(samples),
                    sampleCount: samples.count,
                    durationSeconds: durationSeconds,
                    language: fixture.language,
                    finalWindowCount: cache.cachedWindowCount + 1,
                    cachedClosedWindowCount: cache.cachedWindowCount,
                    cachedInputBytes: cache.totalInputByteCount,
                    totalPrecomputeWallMilliseconds: cache.totalPrecomputeWallMilliseconds,
                    precomputeDutyPercentOfSpeech:
                        cache.totalPrecomputeWallMilliseconds / (durationSeconds * 1_000) * 100,
                    allClosedWindowsReadyBeforeStop: schedules.allSatisfy { $0.slackBeforeStopSeconds >= 0 },
                    minimumReadySlackSeconds: minimumSlack,
                    schedules: schedules,
                    baselineWallMilliseconds: baselineWalls,
                    cachedFinalWallMilliseconds: cachedWalls,
                    baselineP50Milliseconds: baselineP50,
                    baselineP95Milliseconds: percentile(baselineWalls, fraction: 0.95),
                    cachedFinalP50Milliseconds: cachedP50,
                    cachedFinalP95Milliseconds: percentile(cachedWalls, fraction: 0.95),
                    p50StopLatencySpeedup: baselineP50 / cachedP50,
                    baselineTranscript: baselineTexts.first ?? "",
                    cachedTranscript: cachedTexts.first ?? "",
                    baselineTranscriptHashes: Array(baselineTextSet).sorted(),
                    cachedTranscriptHashes: Array(cachedTextSet).sorted(),
                    baselineTimingHashes: Array(baselineTimingSet).sorted(),
                    cachedTimingHashes: Array(cachedTimingSet).sorted(),
                    baselineTranscriptStable: baselineTextSet.count == 1,
                    cachedTranscriptStable: cachedTextSet.count == 1,
                    baselineTimingsStable: baselineTimingSet.count == 1,
                    cachedTimingsStable: cachedTimingSet.count == 1,
                    transcriptExact: transcriptExact,
                    tokenTimingsExact: timingsExact
                )
            )
            FileHandle.standardError.write(
                Data(
                    "fixture=\(fixture.id) cached=\(cache.cachedWindowCount) exactText=\(transcriptExact) exactTimings=\(timingsExact)\n"
                        .utf8
                )
            )
            guard transcriptExact, timingsExact else {
                throw NSError(domain: "all-closed-cache-bench", code: 42)
            }
        }

        let report = Report(
            schemaVersion: 1,
            applicationHead: "f2b6e8cc66d20f7a07094f79af0faf3ba861af64",
            fluidAudioBaseRevision: "ee9a7f12d91710da53de6d75f8b7160e09eccee4",
            prototypeDiffSHA256: arguments.prototypeDiffSHA256,
            modelDirectory: arguments.modelDirectory,
            modelConfiguration: ".all, encoder=.int8/.all, mel=false, concurrency=4, maxTokens=600",
            cachePolicy:
                "prefix-only plan; silence start sealed after full +/-4s search + 80ms energy window; input complete; isLast=false; final plan and Float bit patterns revalidated",
            repeatCount: arguments.repeats,
            persistentProcess: true,
            modelLoadMilliseconds: modelLoadMilliseconds,
            peakRSSBytes: peakRSSBytes(),
            fixtures: fixtureReports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: arguments.reportPath), options: .atomic)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
