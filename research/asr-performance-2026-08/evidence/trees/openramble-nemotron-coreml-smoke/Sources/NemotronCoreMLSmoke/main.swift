import CoreML
import Darwin
import FluidAudio
import Foundation

struct FixtureManifest: Decodable {
    let schemaVersion: Int
    let sourceRevision: String
    let fixtures: [Fixture]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourceRevision = "source_revision"
        case fixtures
    }
}

struct Fixture: Decodable {
    let id: String
    let language: String
    let pcmPath: String
    let pcmSHA256: String
    let sampleCount: Int
    let reference: String

    enum CodingKeys: String, CodingKey {
        case id, language, reference
        case pcmPath = "pcm_path"
        case pcmSHA256 = "pcm_sha256"
        case sampleCount = "sample_count"
    }
}

struct Measurement: Codable {
    let fixtureID: String
    let language: String
    let repetition: Int
    let sampleCount: Int
    let processNS: UInt64
    let finishNS: UInt64
    let totalNS: UInt64
    let transcript: String
    let detectedLanguage: String?
    let tokenCount: Int
    let processedChunks: Int
    let tokenTimings: [TokenTiming]
}

struct Report: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let fluidAudioRevision: String
    let modelRevision: String
    let modelVariant: String
    let computeUnits: String
    let sourceManifest: String
    let sourceRevision: String
    let warmups: Int
    let repetitions: Int
    let loadNS: UInt64
    let peakRSSBytes: UInt64
    let measurements: [Measurement]
}

enum SmokeError: Error, CustomStringConvertible {
    case usage
    case malformedPCM(String)
    case sampleCount(String, expected: Int, actual: Int)

    var description: String {
        switch self {
        case .usage:
            return "usage: NemotronCoreMLSmoke MODEL_DIR MANIFEST WARMUPS REPEATS OUTPUT"
        case .malformedPCM(let path):
            return "malformed Float32 PCM: \(path)"
        case .sampleCount(let id, let expected, let actual):
            return "sample count mismatch for \(id): expected \(expected), got \(actual)"
        }
    }
}

func elapsedNS(since start: UInt64) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds - start
}

func readPCM(_ fixture: Fixture) throws -> [Float] {
    let data = try Data(contentsOf: URL(fileURLWithPath: fixture.pcmPath), options: .mappedIfSafe)
    guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
        throw SmokeError.malformedPCM(fixture.pcmPath)
    }
    var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
    _ = samples.withUnsafeMutableBytes { destination in
        data.copyBytes(to: destination)
    }
    guard samples.count == fixture.sampleCount else {
        throw SmokeError.sampleCount(fixture.id, expected: fixture.sampleCount, actual: samples.count)
    }
    return samples
}

func languageHint(_ language: String) -> String {
    language.lowercased().hasPrefix("ru") ? "ru-RU" : "en-US"
}

func peakRSSBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
}

@main
struct NemotronCoreMLSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6,
              let warmups = Int(args[3]), warmups >= 0,
              let repetitions = Int(args[4]), repetitions > 0
        else {
            throw SmokeError.usage
        }

        let modelDirectory = URL(fileURLWithPath: args[1], isDirectory: true)
        let manifestURL = URL(fileURLWithPath: args[2])
        let outputURL = URL(fileURLWithPath: args[5])
        let manifest = try JSONDecoder().decode(
            FixtureManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let samplesByID = try Dictionary(
            uniqueKeysWithValues: manifest.fixtures.map { ($0.id, try readPCM($0)) }
        )

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let manager = StreamingNemotronMultilingualAsrManager(configuration: configuration)

        let loadStart = DispatchTime.now().uptimeNanoseconds
        try await manager.loadModels(from: modelDirectory)
        let loadNS = elapsedNS(since: loadStart)

        do {
            if warmups > 0 {
                for warmup in 0..<warmups {
                    for fixture in manifest.fixtures {
                        guard let samples = samplesByID[fixture.id] else { continue }
                        await manager.reset()
                        await manager.setLanguage(languageHint(fixture.language))
                        _ = try await manager.process(samples: samples)
                        _ = try await manager.finish()
                        FileHandle.standardError.write(
                            Data("warmup \(warmup + 1)/\(warmups) \(fixture.id)\n".utf8)
                        )
                    }
                }
            }

            var measurements: [Measurement] = []
            measurements.reserveCapacity(repetitions * manifest.fixtures.count)
            for repetition in 0..<repetitions {
                for fixture in manifest.fixtures {
                    guard let samples = samplesByID[fixture.id] else { continue }
                    await manager.reset()
                    await manager.setLanguage(languageHint(fixture.language))

                    let totalStart = DispatchTime.now().uptimeNanoseconds
                    let processStart = totalStart
                    _ = try await manager.process(samples: samples)
                    let processNS = elapsedNS(since: processStart)

                    let finishStart = DispatchTime.now().uptimeNanoseconds
                    let result = try await manager.finishWithTokenTimings()
                    let finishNS = elapsedNS(since: finishStart)
                    let totalNS = elapsedNS(since: totalStart)
                    let stats = await manager.lastDecodeStats()

                    measurements.append(
                        Measurement(
                            fixtureID: fixture.id,
                            language: fixture.language,
                            repetition: repetition,
                            sampleCount: samples.count,
                            processNS: processNS,
                            finishNS: finishNS,
                            totalNS: totalNS,
                            transcript: result.text,
                            detectedLanguage: stats.detectedLanguage,
                            tokenCount: stats.tokenCount,
                            processedChunks: stats.processedChunks,
                            tokenTimings: result.timings
                        )
                    )
                    FileHandle.standardError.write(
                        Data(
                            "measured \(repetition + 1)/\(repetitions) \(fixture.id) finish_ms=\(Double(finishNS) / 1_000_000)\n".utf8
                        )
                    )
                }
            }

            let report = Report(
                schemaVersion: 1,
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                fluidAudioRevision: "ee9a7f12d91710da53de6d75f8b7160e09eccee4",
                modelRevision: "1a41b75758b0337ff67db7d5408280aaaf23074e",
                modelVariant: "multilingual/2240ms",
                computeUnits: "cpuAndNeuralEngine",
                sourceManifest: manifestURL.path,
                sourceRevision: manifest.sourceRevision,
                warmups: warmups,
                repetitions: repetitions,
                loadNS: loadNS,
                peakRSSBytes: peakRSSBytes(),
                measurements: measurements
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
            await manager.cleanup()
        } catch {
            await manager.cleanup()
            throw error
        }
    }
}
