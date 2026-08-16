@preconcurrency import CoreML
import CryptoKit
import Darwin
import FluidAudio
import Foundation

private let expectedFusedMIL = "ea509bf2e8ab1a2ac3ce7eb4ad2fe3138f0a2031dc8bc1600074a47a757b9ebc"
private let expectedFusedWeight = "9c9476541601bd64b0563f11ad9d1c2a3fdf16eb493e06e45bb6122c600911df"
private let expectedDecoderMIL = "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"
private let expectedDecoderWeight =
  "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"
private let expectedJointMIL = "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"
private let expectedJointWeight = "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"

private struct Manifest: Decodable {
  let schemaVersion: Int
  let sourceManifest: String
  let sourceRevision: String
  let fixtures: [Fixture]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sourceManifest = "source_manifest"
    case sourceRevision = "source_revision"
    case fixtures
  }
}

private struct Fixture: Decodable {
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

private struct StableToken: Codable, Equatable {
  let token: String
  let tokenId: Int
  let startTimeBits: UInt64
  let endTimeBits: UInt64
  let confidenceBits: UInt32
}

private struct StableResult: Codable, Equatable {
  let text: String
  let confidenceBits: UInt32
  let tokens: [StableToken]

  init(_ result: ASRResult) {
    text = result.text
    confidenceBits = result.confidence.bitPattern
    tokens = (result.tokenTimings ?? []).map {
      StableToken(
        token: $0.token,
        tokenId: $0.tokenId,
        startTimeBits: $0.startTime.bitPattern,
        endTimeBits: $0.endTime.bitPattern,
        confidenceBits: $0.confidence.bitPattern
      )
    }
  }
}

private struct MeasuredRun: Codable {
  let elapsedNanoseconds: UInt64
  let stable: StableResult
  let diagnostics: TdtCachedFusionDiagnostics?
}

private struct FixtureReport: Codable {
  let id: String
  let language: String
  let reference: String
  let sampleCount: Int
  let pcmSHA256: String
  let a: [MeasuredRun]
  let b: [MeasuredRun]
  let exactPairParity: [Bool]
  let aStable: Bool
  let bStable: Bool
  let fusedPathHealthy: Bool
  let medianANanoseconds: UInt64
  let medianBNanoseconds: UInt64
  let medianWinFraction: Double
}

private struct ArtifactReport: Codable {
  let shippingDirectory: String
  let fusedModel: String
  let manifest: String
  let manifestSHA256: String
  let decoderMILSHA256: String
  let decoderWeightSHA256: String
  let jointMILSHA256: String
  let jointWeightSHA256: String
  let fusedMILSHA256: String
  let fusedWeightSHA256: String
  let fusedDiskBytes: UInt64
}

private struct Report: Codable {
  let schemaVersion: Int
  let computeUnits: String
  let productConfig: String
  let repeats: Int
  let artifacts: ArtifactReport
  let peakRSSAtStartBytes: UInt64
  let peakRSSAfterShippingLoadBytes: UInt64
  let peakRSSAfterFusedLoadBytes: UInt64
  let shippingLoadNanoseconds: UInt64
  let fusedLoadNanoseconds: UInt64
  let fixtures: [FixtureReport]
  let exactFixtureParityCount: Int
  let fusedPathHealthyCount: Int
  let noFixtureMedianSlower: Bool
  let overallMedianANanoseconds: UInt64
  let overallMedianBNanoseconds: UInt64
  let overallMedianWinFraction: Double
  let accepted: Bool
}

private struct Arguments {
  let shippingDirectory: String
  let fusedModel: String
  let manifest: String
  let repeats: Int
  let report: String

  init(_ values: [String]) throws {
    guard values.count == 5, let repeats = Int(values[3]), repeats >= 3 else {
      throw NSError(
        domain: "fused-tdt-smoke",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "usage: fused-tdt-smoke SHIPPING_DIR FUSED_MLMODELC MANIFEST REPEATS REPORT"
        ]
      )
    }
    shippingDirectory = values[0]
    fusedModel = values[1]
    manifest = values[2]
    self.repeats = repeats
    report = values[4]
  }
}

@inline(__always)
private func now() -> UInt64 {
  DispatchTime.now().uptimeNanoseconds
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func fileSHA256(_ path: String) throws -> String {
  sha256(try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe))
}

private func requireHash(_ path: String, _ expected: String) throws -> String {
  let actual = try fileSHA256(path)
  guard actual == expected else {
    throw NSError(
      domain: "fused-tdt-smoke",
      code: 3,
      userInfo: [NSLocalizedDescriptionKey: "SHA mismatch for \(path): \(actual) != \(expected)"]
    )
  }
  return actual
}

private func directoryBytes(_ path: String) -> UInt64 {
  guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
  var total: UInt64 = 0
  for case let relative as String in enumerator {
    let full = (path as NSString).appendingPathComponent(relative)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: full),
      let type = attributes[.type] as? FileAttributeType,
      type == .typeRegular,
      let size = attributes[.size] as? NSNumber
    else { continue }
    total += size.uint64Value
  }
  return total
}

private func peakRSSBytes() -> UInt64 {
  var usage = rusage()
  guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
  return UInt64(max(0, usage.ru_maxrss))
}

private func readPCM(_ fixture: Fixture) throws -> [Float] {
  let data = try Data(contentsOf: URL(fileURLWithPath: fixture.pcmPath), options: .mappedIfSafe)
  guard sha256(data) == fixture.pcmSHA256,
    data.count == fixture.sampleCount * MemoryLayout<Float>.size
  else {
    throw NSError(
      domain: "fused-tdt-smoke",
      code: 4,
      userInfo: [NSLocalizedDescriptionKey: "PCM seal mismatch for \(fixture.id)"]
    )
  }
  return data.withUnsafeBytes { rawBuffer in
    Array(rawBuffer.bindMemory(to: Float.self))
  }
}

private func median(_ values: [UInt64]) -> UInt64 {
  let sorted = values.sorted()
  if sorted.count.isMultiple(of: 2) {
    let upper = sorted[sorted.count / 2]
    let lower = sorted[sorted.count / 2 - 1]
    return lower / 2 + upper / 2 + (lower % 2 + upper % 2) / 2
  }
  return sorted[sorted.count / 2]
}

private func measured(
  manager: AsrManager,
  samples: [Float],
  language: Language
) async throws -> MeasuredRun {
  var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
  let started = now()
  let result = try await manager.transcribe(samples, decoderState: &state, language: language)
  return MeasuredRun(
    elapsedNanoseconds: now() - started,
    stable: StableResult(result),
    diagnostics: result.cachedFusionDiagnostics
  )
}

@main
private enum FusedTdtSmoke {
  static func main() async throws {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    let shipping = arguments.shippingDirectory
    let fused = arguments.fusedModel
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: arguments.manifest))
    let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
    guard manifest.schemaVersion == 1, manifest.fixtures.count == 4 else {
      throw NSError(domain: "fused-tdt-smoke", code: 5)
    }

    let artifactReport = try ArtifactReport(
      shippingDirectory: shipping,
      fusedModel: fused,
      manifest: arguments.manifest,
      manifestSHA256: sha256(manifestData),
      decoderMILSHA256: requireHash("\(shipping)/Decoder.mlmodelc/model.mil", expectedDecoderMIL),
      decoderWeightSHA256: requireHash(
        "\(shipping)/Decoder.mlmodelc/weights/weight.bin", expectedDecoderWeight),
      jointMILSHA256: requireHash(
        "\(shipping)/JointDecisionv3.mlmodelc/model.mil", expectedJointMIL),
      jointWeightSHA256: requireHash(
        "\(shipping)/JointDecisionv3.mlmodelc/weights/weight.bin", expectedJointWeight),
      fusedMILSHA256: requireHash("\(fused)/model.mil", expectedFusedMIL),
      fusedWeightSHA256: requireHash("\(fused)/weights/weight.bin", expectedFusedWeight),
      fusedDiskBytes: directoryBytes(fused)
    )

    let samplesByID = try Dictionary(
      uniqueKeysWithValues: manifest.fixtures.map { ($0.id, try readPCM($0)) })
    let peakRSSAtStart = peakRSSBytes()

    ModelHub.offlineMode = true
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let shippingLoadStart = now()
    let shippingModels = try await AsrModels.load(
      from: URL(fileURLWithPath: shipping, isDirectory: true),
      configuration: configuration,
      version: .v3,
      encoderPrecision: .int8,
      encoderComputeUnits: .all
    )
    let shippingLoadNanoseconds = now() - shippingLoadStart
    let peakRSSAfterShippingLoad = peakRSSBytes()

    let fusedLoadStart = now()
    let fusedModel = try MLModel(
      contentsOf: URL(fileURLWithPath: fused, isDirectory: true),
      configuration: configuration
    )
    let fusedLoadNanoseconds = now() - fusedLoadStart
    let peakRSSAfterFusedLoad = peakRSSBytes()

    let fusedModels = AsrModels(
      encoder: shippingModels.encoder,
      preprocessor: shippingModels.preprocessor,
      decoder: shippingModels.decoder,
      joint: shippingModels.joint,
      cachedFusedDecoderJoint: fusedModel,
      ctcHead: shippingModels.ctcHead,
      configuration: configuration,
      vocabulary: shippingModels.vocabulary,
      version: .v3
    )
    let productConfig = ASRConfig(
      tdtConfig: TdtConfig(maxTokensPerChunk: 600),
      parallelChunkConcurrency: 4,
      melChunkContext: false,
      dualDecodeArbitration: false
    )
    let managerA = AsrManager(config: productConfig)
    let managerB = AsrManager(config: productConfig)
    try await managerA.loadModels(shippingModels)
    try await managerB.loadModels(fusedModels)

    var fixtureReports: [FixtureReport] = []
    var allATimes: [UInt64] = []
    var allBTimes: [UInt64] = []
    for fixture in manifest.fixtures {
      guard let samples = samplesByID[fixture.id],
        let language = Language(rawValue: fixture.language)
      else {
        throw NSError(domain: "fused-tdt-smoke", code: 6)
      }

      _ = try await measured(manager: managerA, samples: samples, language: language)
      _ = try await measured(manager: managerB, samples: samples, language: language)

      var runsA: [MeasuredRun] = []
      var runsB: [MeasuredRun] = []
      for repetition in 0..<arguments.repeats {
        if repetition.isMultiple(of: 2) {
          runsA.append(try await measured(manager: managerA, samples: samples, language: language))
          runsB.append(try await measured(manager: managerB, samples: samples, language: language))
        } else {
          runsB.append(try await measured(manager: managerB, samples: samples, language: language))
          runsA.append(try await measured(manager: managerA, samples: samples, language: language))
        }
      }

      let parity = zip(runsA, runsB).map { $0.stable == $1.stable }
      let stableA = runsA.dropFirst().allSatisfy { $0.stable == runsA[0].stable }
      let stableB = runsB.dropFirst().allSatisfy { $0.stable == runsB[0].stable }
      let fusedPathHealthy = runsB.allSatisfy { run in
        guard let diagnostics = run.diagnostics else { return false }
        let fusedCalls = diagnostics.fusedSOSCalls + diagnostics.fusedTokenCalls
        return diagnostics.fallbacks == 0
          && diagnostics.prefetchedFrameMismatches == 0
          && diagnostics.fusedSOSCalls == 1
          && diagnostics.prefetchedDecisionsConsumed == fusedCalls
          && diagnostics.backingPoolAllocations == 1
          && diagnostics.backingPoolLogicalBytes > 0
          && diagnostics.backingIdentityValidations == fusedCalls
          && diagnostics.backingSlot0Calls + diagnostics.backingSlot1Calls == fusedCalls
          && diagnostics.backingSlot0Calls > 0
          && diagnostics.backingSlot1Calls > 0
          && diagnostics.fusedDetachedStateLogicalBytes == 0
          && diagnostics.fusedPreallocatedStateLogicalBytesWritten
            == UInt64(fusedCalls * 12_800)
          && diagnostics.fusedFiniteScanWallNanoseconds > 0
      }
      let timesA = runsA.map(\.elapsedNanoseconds)
      let timesB = runsB.map(\.elapsedNanoseconds)
      let medianA = median(timesA)
      let medianB = median(timesB)
      let win = Double(Int64(medianA) - Int64(medianB)) / Double(medianA)
      allATimes.append(contentsOf: timesA)
      allBTimes.append(contentsOf: timesB)
      fixtureReports.append(
        FixtureReport(
          id: fixture.id,
          language: fixture.language,
          reference: fixture.reference,
          sampleCount: fixture.sampleCount,
          pcmSHA256: fixture.pcmSHA256,
          a: runsA,
          b: runsB,
          exactPairParity: parity,
          aStable: stableA,
          bStable: stableB,
          fusedPathHealthy: fusedPathHealthy,
          medianANanoseconds: medianA,
          medianBNanoseconds: medianB,
          medianWinFraction: win
        )
      )
    }

    let exactFixtureParityCount = fixtureReports.filter {
      $0.aStable && $0.bStable && $0.exactPairParity.allSatisfy { $0 }
    }.count
    let fusedPathHealthyCount = fixtureReports.filter(\.fusedPathHealthy).count
    let noFixtureMedianSlower = fixtureReports.allSatisfy { $0.medianWinFraction >= 0 }
    let overallMedianA = median(allATimes)
    let overallMedianB = median(allBTimes)
    let overallWin = Double(Int64(overallMedianA) - Int64(overallMedianB)) / Double(overallMedianA)
    let accepted =
      exactFixtureParityCount == 4 && fusedPathHealthyCount == 4
      && noFixtureMedianSlower && overallWin >= 0.05
    let report = Report(
      schemaVersion: 2,
      computeUnits: "MLComputeUnits.all",
      productConfig:
        "mel=false/concurrency=4/TDT.maxTokensPerChunk=600/dualDecode=false/resetData=false",
      repeats: arguments.repeats,
      artifacts: artifactReport,
      peakRSSAtStartBytes: peakRSSAtStart,
      peakRSSAfterShippingLoadBytes: peakRSSAfterShippingLoad,
      peakRSSAfterFusedLoadBytes: peakRSSAfterFusedLoad,
      shippingLoadNanoseconds: shippingLoadNanoseconds,
      fusedLoadNanoseconds: fusedLoadNanoseconds,
      fixtures: fixtureReports,
      exactFixtureParityCount: exactFixtureParityCount,
      fusedPathHealthyCount: fusedPathHealthyCount,
      noFixtureMedianSlower: noFixtureMedianSlower,
      overallMedianANanoseconds: overallMedianA,
      overallMedianBNanoseconds: overallMedianB,
      overallMedianWinFraction: overallWin,
      accepted: accepted
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let output = try encoder.encode(report)
    try output.write(to: URL(fileURLWithPath: arguments.report), options: .atomic)
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if !accepted { exit(10) }
  }
}
