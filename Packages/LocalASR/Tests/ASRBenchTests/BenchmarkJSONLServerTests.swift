import Foundation
import XCTest
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
}
