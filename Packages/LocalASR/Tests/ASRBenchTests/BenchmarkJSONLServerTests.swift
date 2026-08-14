import Foundation
import XCTest
import DictationCore
@testable import asr_bench

final class BenchmarkJSONLServerTests: XCTestCase {
    func testCanonicalPCMUsesLittleEndianFloat32Bits() {
        let data = BenchmarkJSONLServer.canonicalPCM([1, -2, 0.5])

        XCTAssertEqual(
            Array(data),
            [
                0x00, 0x00, 0x80, 0x3f,
                0x00, 0x00, 0x00, 0xc0,
                0x00, 0x00, 0x00, 0x3f,
            ]
        )
    }

    func testCanonicalPCMFileRoundTripsExactBitPatterns() throws {
        let values: [Float] = [0, -0.0, 0.25, -Float.greatestFiniteMagnitude]
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "fixture.f32le")
        try BenchmarkJSONLServer.canonicalPCM(values).write(to: url)

        let decoded = try BenchmarkJSONLServer.decodeCanonicalPCM(at: url)

        XCTAssertEqual(decoded.map(\.bitPattern), values.map(\.bitPattern))
    }

    func testCanonicalPCMRejectsIncompleteAndNonFiniteInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "broken.f32le")
        try Data([0, 1, 2]).write(to: url)

        XCTAssertThrowsError(try BenchmarkJSONLServer.decodeCanonicalPCM(at: url))
        XCTAssertThrowsError(try BenchmarkJSONLServer.validate(samples: []))
        XCTAssertThrowsError(try BenchmarkJSONLServer.validate(samples: [.nan]))
        XCTAssertNoThrow(try BenchmarkJSONLServer.validate(samples: [0, 1]))
    }

    func testRunResponseEmitsVersionedPhaseTimingWithStableNulls() throws {
        let result = ASRResult(
            text: "hello",
            audioDuration: 1,
            processingDuration: 0.1,
            phaseTimings: ASRPhaseTimings(
                primaryTDTInferenceDecodeNanoseconds: 10,
                lexicalCandidateGateNanoseconds: 20,
                ctcModelInferenceNanoseconds: nil,
                ctcRescoringFusionNanoseconds: nil,
                ctcInferenceInvocations: 0,
                vocabularyOutcome: .noCandidate,
                phasesMayOverlap: false
            )
        )

        let response = BenchmarkJSONLServer.runResponse(
            requestID: 7,
            command: "run",
            elapsed: 100,
            result: result,
            pcmHash: String(repeating: "a", count: 64),
            sampleCount: 16_000,
            didPrewarm: true
        )
        let timing = try XCTUnwrap(response["timing"] as? [String: Any])
        let phases = try XCTUnwrap(timing["phases"] as? [String: Any])

        XCTAssertEqual(timing["schema_version"] as? Int, 1)
        XCTAssertEqual(timing["clock"] as? String, "monotonic_uptime")
        XCTAssertEqual(timing["total_wall_ns"] as? UInt64, 100)
        XCTAssertEqual(timing["total_wall_scope"] as? String, "predecoded_transcribe")
        XCTAssertEqual(timing["phases_may_overlap"] as? Bool, false)
        XCTAssertEqual(phases["primary_tdt_inference_decode_ns"] as? UInt64, 10)
        XCTAssertEqual(phases["lexical_candidate_gate_ns"] as? UInt64, 20)
        XCTAssertTrue(phases["ctc_model_inference_ns"] is NSNull)
        XCTAssertTrue(phases["ctc_rescoring_fusion_ns"] is NSNull)
        XCTAssertEqual(timing["ctc_inference_invocations"] as? Int, 0)
        XCTAssertEqual(timing["vocabulary_outcome"] as? String, "no_candidate")
    }
}
