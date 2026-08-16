import CoreML
import CryptoKit
import Darwin
import Foundation
import FluidAudio

private struct Manifest: Decodable { let fixtures: [Fixture] }

private struct Fixture: Decodable {
    let id: String
    let path: String
    let language: String?
    let sha256: String
}

private struct FixtureResult: Encodable {
    let id: String
    let path: String
    let language: String?
    let expectedSourceSHA256: String
    let actualSourceSHA256: String
    let sourceHashMatches: Bool
    let sampleCount: Int
    let durationSeconds: Double
    let firstTranscript: String
    let transcriptSHA256: String
    let transcriptVariants: [String]
    let transcriptStable: Bool
    let firstTokenTimingsSHA256: String
    let tokenTimingHashVariants: [String]
    let tokenTimingsStable: Bool
    let firstTokenTimings: [TokenTiming]
    let wallNanoseconds: [UInt64]
    let orchestrationResidualNanoseconds: [Int64]
    let tdtSwiftResidualNanoseconds: [Int64]
    let phases: [TempASRPhaseSnapshot]
}

private struct ShippingConfiguration: Encodable {
    let computeUnits: String
    let encoderComputeUnits: String
    let encoderPrecision: String
    let melChunkContext: Bool
    let parallelChunkConcurrency: Int
    let maxTokensPerChunk: Int
    let dualDecodeArbitration: Bool
    let cacheReturnResetData: Bool
}

private struct Report: Encodable {
    let schemaVersion: Int
    let applicationHead: String
    let fluidAudioBaseRevision: String
    let modelDirectory: String
    let modelWindowSeconds: Double
    let maxModelSamples: Int
    let decoderComputeUnitsOverride: String
    let jointComputeUnitsOverride: String
    let warmupCountPerFixture: Int
    let repeatCountPerFixture: Int
    let persistentProcess: Bool
    let shippingConfiguration: ShippingConfiguration
    let modelLoadNanoseconds: UInt64
    let managerLoadNanoseconds: UInt64
    let firstInferenceNanoseconds: UInt64
    let firstInferenceTranscript: String
    let peakRSSAtStartBytes: UInt64
    let peakRSSAfterModelLoadBytes: UInt64
    let peakRSSAfterFirstInferenceBytes: UInt64
    let peakRSSAtEndBytes: UInt64
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
                domain: "phase-bench", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "usage: phase-bench MODEL_DIR MANIFEST WARMUPS REPEATS WINDOW_SECONDS REPORT_PATH"])
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
private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func peakRSSBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func stableHash<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256(try encoder.encode(value))
}

private func exclusiveAccounted(_ phase: TempASRPhaseSnapshot) -> UInt64 {
    phase.alignmentAndPaddingNanoseconds
        + phase.preprocessorInputNanoseconds
        + phase.preprocessorPredictionNanoseconds
        + phase.encoderInputNanoseconds
        + phase.encoderPredictionNanoseconds
        + phase.frontendOutputExtractionNanoseconds
        + phase.tdtDecodeNanoseconds
        + phase.cacheReturnNanoseconds
        + phase.resultProcessingNanoseconds
}

@main
private enum PhaseBench {
    static func main() async throws {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        let envWindow = ProcessInfo.processInfo.environment["OPENRAMBLE_TEMP_MODEL_WINDOW_SECONDS"]
            .flatMap(Double.init)
        guard let envWindow, abs(envWindow - arguments.modelWindowSeconds) < 0.000_001 else {
            throw NSError(
                domain: "phase-bench", code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "OPENRAMBLE_TEMP_MODEL_WINDOW_SECONDS must match WINDOW_SECONDS"])
        }

        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments.manifestPath)))
        precondition(manifest.fixtures.count >= 4)

        let converter = AudioConverter()
        var samplesByID: [String: [Float]] = [:]
        for fixture in manifest.fixtures {
            samplesByID[fixture.id] = try converter.resampleAudioFile(path: fixture.path)
        }

        ModelHub.offlineMode = true
        let peakStart = peakRSSBytes()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let modelLoadStart = now()
        let models = try await AsrModels.load(
            from: URL(fileURLWithPath: arguments.modelDirectory, isDirectory: true),
            configuration: configuration,
            version: .v3,
            encoderPrecision: .int8,
            encoderComputeUnits: .all)
        let modelLoadNanoseconds = now() - modelLoadStart
        let peakAfterModelLoad = peakRSSBytes()

        let manager = AsrManager(config: ASRConfig(
            tdtConfig: TdtConfig(maxTokensPerChunk: 600),
            parallelChunkConcurrency: 4,
            melChunkContext: false,
            dualDecodeArbitration: false))
        let managerLoadStart = now()
        try await manager.loadModels(models)
        let managerLoadNanoseconds = now() - managerLoadStart

        let firstFixture = manifest.fixtures[0]
        let firstSamples = samplesByID[firstFixture.id]!
        var firstState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        TempASRPhaseDiagnostics.begin()
        let firstStart = now()
        let firstResult = try await manager.transcribe(
            firstSamples, decoderState: &firstState,
            language: firstFixture.language.flatMap(Language.init(rawValue:)))
        let firstInferenceNanoseconds = now() - firstStart
        _ = TempASRPhaseDiagnostics.finish()
        let peakAfterFirst = peakRSSBytes()

        var fixtureResults: [FixtureResult] = []
        for fixture in manifest.fixtures {
            let samples = samplesByID[fixture.id]!
            let language = fixture.language.flatMap(Language.init(rawValue:))

            for _ in 0..<arguments.warmupCount {
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                TempASRPhaseDiagnostics.begin()
                _ = try await manager.transcribe(samples, decoderState: &state, language: language)
                _ = TempASRPhaseDiagnostics.finish()
            }

            var walls: [UInt64] = []
            var orchestrationResiduals: [Int64] = []
            var tdtSwiftResiduals: [Int64] = []
            var phases: [TempASRPhaseSnapshot] = []
            var transcripts: Set<String> = []
            var timingHashes: Set<String> = []
            var firstTranscript = ""
            var firstTimings: [TokenTiming] = []
            var firstTimingsHash = ""

            for repetition in 0..<arguments.repeatCount {
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                TempASRPhaseDiagnostics.begin()
                let wallStart = now()
                let result = try await manager.transcribe(samples, decoderState: &state, language: language)
                let wall = now() - wallStart
                let phase = TempASRPhaseDiagnostics.finish()
                let timings = result.tokenTimings ?? []
                let timingsHash = try stableHash(timings)

                walls.append(wall)
                orchestrationResiduals.append(Int64(wall) - Int64(exclusiveAccounted(phase)))
                tdtSwiftResiduals.append(
                    Int64(phase.tdtDecodeNanoseconds)
                        - Int64(phase.decoderPredictionNanoseconds)
                        - Int64(phase.jointPredictionNanoseconds))
                phases.append(phase)
                transcripts.insert(result.text)
                timingHashes.insert(timingsHash)
                if repetition == 0 {
                    firstTranscript = result.text
                    firstTimings = timings
                    firstTimingsHash = timingsHash
                }
            }

            let actualHash = sha256(try Data(contentsOf: URL(fileURLWithPath: fixture.path)))
            fixtureResults.append(FixtureResult(
                id: fixture.id,
                path: fixture.path,
                language: fixture.language,
                expectedSourceSHA256: fixture.sha256,
                actualSourceSHA256: actualHash,
                sourceHashMatches: actualHash == fixture.sha256,
                sampleCount: samples.count,
                durationSeconds: Double(samples.count) / 16_000.0,
                firstTranscript: firstTranscript,
                transcriptSHA256: sha256(Data(firstTranscript.utf8)),
                transcriptVariants: transcripts.sorted(),
                transcriptStable: transcripts.count == 1,
                firstTokenTimingsSHA256: firstTimingsHash,
                tokenTimingHashVariants: timingHashes.sorted(),
                tokenTimingsStable: timingHashes.count == 1,
                firstTokenTimings: firstTimings,
                wallNanoseconds: walls,
                orchestrationResidualNanoseconds: orchestrationResiduals,
                tdtSwiftResidualNanoseconds: tdtSwiftResiduals,
                phases: phases))
            FileHandle.standardError.write(Data(
                "complete fixture=\(fixture.id) repeats=\(arguments.repeatCount)\n".utf8))
        }

        let report = Report(
            schemaVersion: 1,
            applicationHead: "f2b6e8cc66d20f7a07094f79af0faf3ba861af64",
            fluidAudioBaseRevision: "ee9a7f12d91710da53de6d75f8b7160e09eccee4",
            modelDirectory: arguments.modelDirectory,
            modelWindowSeconds: arguments.modelWindowSeconds,
            maxModelSamples: ASRConstants.maxModelSamples,
            decoderComputeUnitsOverride: ProcessInfo.processInfo.environment[
                "OPENRAMBLE_TEMP_DECODER_COMPUTE_UNITS"] ?? "all",
            jointComputeUnitsOverride: ProcessInfo.processInfo.environment[
                "OPENRAMBLE_TEMP_JOINT_COMPUTE_UNITS"] ?? "all",
            warmupCountPerFixture: arguments.warmupCount,
            repeatCountPerFixture: arguments.repeatCount,
            persistentProcess: true,
            shippingConfiguration: ShippingConfiguration(
                computeUnits: "MLComputeUnits.all",
                encoderComputeUnits: "MLComputeUnits.all",
                encoderPrecision: "int8",
                melChunkContext: false,
                parallelChunkConcurrency: 4,
                maxTokensPerChunk: 600,
                dualDecodeArbitration: false,
                cacheReturnResetData: false),
            modelLoadNanoseconds: modelLoadNanoseconds,
            managerLoadNanoseconds: managerLoadNanoseconds,
            firstInferenceNanoseconds: firstInferenceNanoseconds,
            firstInferenceTranscript: firstResult.text,
            peakRSSAtStartBytes: peakStart,
            peakRSSAfterModelLoadBytes: peakAfterModelLoad,
            peakRSSAfterFirstInferenceBytes: peakAfterFirst,
            peakRSSAtEndBytes: peakRSSBytes(),
            fixtures: fixtureResults)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: arguments.reportPath), options: .atomic)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
