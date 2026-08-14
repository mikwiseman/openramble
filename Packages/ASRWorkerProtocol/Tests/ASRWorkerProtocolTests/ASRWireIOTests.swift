import Darwin
import Foundation
import Testing
@testable import ASRWorkerProtocol

@Suite("ASR worker wire framing")
struct ASRWireIOTests {
    @Test("metadata and raw PCM survive arbitrary pipe fragmentation")
    func roundTrip() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        try ASRWireIO.disableSIGPIPE(on: descriptors[1])

        let metadata = try ASRWorkerJSON.encode(
            ASRWorkerTranscribeSamples(sampleRate: 16_000, sampleCount: 4, languageHint: "ru")
        )
        let floats: [Float] = [0, -0.5, 0.25, 1]
        let payload = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        let original = ASRWireFrame(
            kind: .transcribeSamples,
            requestID: 42,
            metadata: metadata,
            payload: payload
        )

        try ASRWireIO.write(original, to: descriptors[1])
        let received = try ASRWireIO.read(from: descriptors[0])
        let decoded = try #require(received)
        #expect(decoded == original)
    }

    @Test("oversized payload is rejected before writing")
    func oversizedPayload() throws {
        let frame = ASRWireFrame(
            kind: .transcribeSamples,
            requestID: 1,
            metadata: Data([0x7b, 0x7d]),
            payload: Data(count: ASRWorkerProtocol.maximumPCMBytes + 1)
        )
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        #expect(throws: ASRWireError.self) {
            try ASRWireIO.write(frame, to: descriptors[1])
        }
    }

    @Test("clean EOF differs from a truncated frame")
    func eofSemantics() throws {
        var clean: [Int32] = [0, 0]
        #expect(pipe(&clean) == 0)
        Darwin.close(clean[1])
        #expect(try ASRWireIO.read(from: clean[0]) == nil)
        Darwin.close(clean[0])

        var truncated: [Int32] = [0, 0]
        #expect(pipe(&truncated) == 0)
        _ = Darwin.write(truncated[1], [UInt8](repeating: 0, count: 3), 3)
        Darwin.close(truncated[1])
        #expect(throws: ASRWireError.truncatedFrame) {
            _ = try ASRWireIO.read(from: truncated[0])
        }
        Darwin.close(truncated[0])
    }

    @Test("declared lengths are rejected before allocating or reading bodies")
    func hostileDeclaredLength() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        let header = makeHeader(
            kind: ASRWireKind.result.rawValue,
            requestID: 99,
            metadataBytes: UInt32(ASRWorkerProtocol.maximumMetadataBytes + 1),
            payloadBytes: 0
        )
        _ = header.withUnsafeBytes {
            Darwin.write(descriptors[1], $0.baseAddress, $0.count)
        }
        #expect(throws: ASRWireError.self) {
            _ = try ASRWireIO.read(from: descriptors[0])
        }
    }

    @Test("unknown message kinds fail closed")
    func unknownMessageKind() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        let header = makeHeader(kind: UInt16.max, requestID: 1, metadataBytes: 0, payloadBytes: 0)
        _ = header.withUnsafeBytes {
            Darwin.write(descriptors[1], $0.baseAddress, $0.count)
        }
        #expect(throws: ASRWireError.unknownMessageKind(UInt16.max)) {
            _ = try ASRWireIO.read(from: descriptors[0])
        }
    }

    @Test("a closed peer reports EPIPE instead of terminating the app")
    func sigpipeSafety() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        Darwin.close(descriptors[0])
        defer { Darwin.close(descriptors[1]) }
        try ASRWireIO.disableSIGPIPE(on: descriptors[1])

        #expect(throws: ASRWireError.self) {
            try ASRWireIO.write(
                ASRWireFrame(kind: .shutdown, requestID: 1, metadata: Data("{}".utf8)),
                to: descriptors[1]
            )
        }
    }

    private func makeHeader(
        kind: UInt16,
        requestID: UInt64,
        metadataBytes: UInt32,
        payloadBytes: UInt64
    ) -> Data {
        var header = Data([0x4f, 0x52, 0x41, 0x53])
        append(ASRWorkerProtocol.version, to: &header)
        append(kind, to: &header)
        append(requestID, to: &header)
        append(metadataBytes, to: &header)
        append(payloadBytes, to: &header)
        return header
    }

    private func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
