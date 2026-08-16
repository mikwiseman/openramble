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

private struct FixtureReport: Encodable {
    let id: String
    let path: String
    let expectedSourceSHA256: String
    let actualSourceSHA256: String
    let sourceHashMatches: Bool
    let sampleCount: Int
    let durationSeconds: Double
    let language: String?
    let cacheInputStartSample: Int
    let cacheInputEndSample: Int
    let cacheInputSampleCount: Int
    let earliestSafePrefixSampleCount: Int
    let earliestSafePrefixSeconds: Double
    let speechSlackAfterSafePrefixMilliseconds: Double
    let precomputeWallMilliseconds: Double
    let precomputeCouldFinishBeforeStop: Bool
    let cachedTokenCount: Int
    let baselineWallMilliseconds: [Double]
    let cachedFinalWallMilliseconds: [Double]
    let baselineP50Milliseconds: Double
    let cachedFinalP50Milliseconds: Double
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
    let repeatCount: Int
    let persistentProcess: Bool
    let warmupFixture: String
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
                domain: "closed-cache-bench",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "usage: closed-cache-bench MODEL_DIR MANIFEST REPORT REPEATS PROTOTYPE_DIFF_SHA256"
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

private let selectedFixtureIDs: Set<String> = [
    "boundary-en-repeat-15.1s",
    "boundary-en-repeat-29.9s",
    "boundary-en-repeat-30.1s",
    "real-en-product-names-56.104s",
]

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func stableHash<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256(try encoder.encode(value))
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1e15
}

private func percentile50(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func peakRSSBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
}

@main
private enum ClosedCacheBench {
    static func main() async throws {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        let sourceManifest = try JSONDecoder().decode(
            SourceManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments.manifestPath))
        )
        let fixtures = sourceManifest.fixtures.filter { selectedFixtureIDs.contains($0.id) }
        guard fixtures.count == selectedFixtureIDs.count else {
            throw NSError(domain: "closed-cache-bench", code: 3)
        }

        let converter = AudioConverter()
        var samplesByID: [String: [Float]] = [:]
        for fixture in fixtures {
            samplesByID[fixture.id] = try converter.resampleAudioFile(path: fixture.path)
        }

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

        let warmupFixture = fixtures.first { $0.id == "boundary-en-repeat-15.1s" }!
        var warmupState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe(
            samplesByID[warmupFixture.id]!,
            decoderState: &warmupState,
            language: warmupFixture.language.flatMap(Language.init(rawValue:))
        )

        var fixtureReports: [FixtureReport] = []
        for fixture in fixtures {
            let samples = samplesByID[fixture.id]!
            let language = fixture.language.flatMap(Language.init(rawValue:))
            let earliestSafePrefixCount = ASRConstants.maxModelSamples + 1
            guard samples.count > earliestSafePrefixCount else {
                throw NSError(domain: "closed-cache-bench", code: 4)
            }

            let prefix = Array(samples.prefix(earliestSafePrefixCount))
            let precomputeStarted = ContinuousClock.now
            let cache = try await manager.tempPrecomputeFirstClosedChunk(prefix, language: language)
            let precomputeMilliseconds = milliseconds(precomputeStarted.duration(to: .now))

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
                let cached = try await manager.tempTranscribeUsingFirstClosedChunk(
                    samples,
                    cache: cache,
                    language: language
                )
                cachedWalls.append(milliseconds(cachedStarted.duration(to: .now)))
                cachedTexts.append(cached.text)
                cachedTextHashes.append(sha256(Data(cached.text.utf8)))
                cachedTimingHashes.append(try stableHash(cached.tokenTimings ?? []))
            }

            let baselineP50 = percentile50(baselineWalls)
            let cachedP50 = percentile50(cachedWalls)
            let slackMilliseconds =
                (Double(samples.count - cache.earliestSafePrefixSampleCount) / 16_000) * 1_000
            let baselineHashSet = Set(baselineTextHashes)
            let cachedHashSet = Set(cachedTextHashes)
            let baselineTimingHashSet = Set(baselineTimingHashes)
            let cachedTimingHashSet = Set(cachedTimingHashes)
            let transcriptExact =
                baselineHashSet.count == 1
                && cachedHashSet.count == 1
                && baselineHashSet == cachedHashSet
            let timingsExact =
                baselineTimingHashSet.count == 1
                && cachedTimingHashSet.count == 1
                && baselineTimingHashSet == cachedTimingHashSet

            fixtureReports.append(
                FixtureReport(
                    id: fixture.id,
                    path: fixture.path,
                    expectedSourceSHA256: fixture.sha256,
                    actualSourceSHA256: sha256(try Data(contentsOf: URL(fileURLWithPath: fixture.path))),
                    sourceHashMatches: sha256(try Data(contentsOf: URL(fileURLWithPath: fixture.path)))
                        == fixture.sha256,
                    sampleCount: samples.count,
                    durationSeconds: Double(samples.count) / 16_000,
                    language: fixture.language,
                    cacheInputStartSample: cache.inputStartSample,
                    cacheInputEndSample: cache.inputEndSample,
                    cacheInputSampleCount: cache.inputSampleCount,
                    earliestSafePrefixSampleCount: cache.earliestSafePrefixSampleCount,
                    earliestSafePrefixSeconds: cache.earliestSafePrefixSeconds,
                    speechSlackAfterSafePrefixMilliseconds: slackMilliseconds,
                    precomputeWallMilliseconds: precomputeMilliseconds,
                    precomputeCouldFinishBeforeStop: precomputeMilliseconds <= slackMilliseconds,
                    cachedTokenCount: cache.tokenCount,
                    baselineWallMilliseconds: baselineWalls,
                    cachedFinalWallMilliseconds: cachedWalls,
                    baselineP50Milliseconds: baselineP50,
                    cachedFinalP50Milliseconds: cachedP50,
                    p50StopLatencySpeedup: baselineP50 / cachedP50,
                    baselineTranscript: baselineTexts.first ?? "",
                    cachedTranscript: cachedTexts.first ?? "",
                    baselineTranscriptHashes: Array(baselineHashSet).sorted(),
                    cachedTranscriptHashes: Array(cachedHashSet).sorted(),
                    baselineTimingHashes: Array(baselineTimingHashSet).sorted(),
                    cachedTimingHashes: Array(cachedTimingHashSet).sorted(),
                    baselineTranscriptStable: baselineHashSet.count == 1,
                    cachedTranscriptStable: cachedHashSet.count == 1,
                    baselineTimingsStable: baselineTimingHashSet.count == 1,
                    cachedTimingsStable: cachedTimingHashSet.count == 1,
                    transcriptExact: transcriptExact,
                    tokenTimingsExact: timingsExact
                )
            )
            FileHandle.standardError.write(
                Data("fixture=\(fixture.id) exactText=\(transcriptExact) exactTimings=\(timingsExact)\n".utf8)
            )
            guard transcriptExact, timingsExact else {
                throw NSError(domain: "closed-cache-bench", code: 42)
            }
        }

        let report = Report(
            schemaVersion: 1,
            applicationHead: "f2b6e8cc66d20f7a07094f79af0faf3ba861af64",
            fluidAudioBaseRevision: "ee9a7f12d91710da53de6d75f8b7160e09eccee4",
            prototypeDiffSHA256: arguments.prototypeDiffSHA256,
            modelDirectory: arguments.modelDirectory,
            modelConfiguration: ".all, encoder=.int8/.all, mel=false, concurrency=4, maxTokens=600",
            repeatCount: arguments.repeats,
            persistentProcess: true,
            warmupFixture: warmupFixture.id,
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
