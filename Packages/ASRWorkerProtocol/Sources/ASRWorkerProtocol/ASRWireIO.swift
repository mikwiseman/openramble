import Darwin
import Foundation

public enum ASRWireError: Error, Equatable, Sendable {
    case invalidMagic
    case protocolMismatch(actual: UInt16)
    case unknownMessageKind(UInt16)
    case metadataTooLarge(actual: Int, maximum: Int)
    case payloadTooLarge(actual: Int, maximum: Int)
    case truncatedFrame
    case systemCall(operation: String, code: Int32)
}

public struct ASRWireFrame: Equatable, Sendable {
    public let kind: ASRWireKind
    public let requestID: UInt64
    public let metadata: Data
    public let payload: Data

    public init(kind: ASRWireKind, requestID: UInt64, metadata: Data, payload: Data = Data()) {
        self.kind = kind
        self.requestID = requestID
        self.metadata = metadata
        self.payload = payload
    }
}

/// Blocking framed I/O. Callers run it on a dedicated thread, never an actor
/// executor or the main thread.
public enum ASRWireIO {
    private static let magic: [UInt8] = [0x4f, 0x52, 0x41, 0x53] // ORAS
    private static let headerBytes = 28

    public static func disableSIGPIPE(on descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ASRWireError.systemCall(operation: "fcntl(F_SETNOSIGPIPE)", code: errno)
        }
    }

    public static func write(_ frame: ASRWireFrame, to descriptor: Int32) throws {
        guard frame.metadata.count <= ASRWorkerProtocol.maximumMetadataBytes else {
            throw ASRWireError.metadataTooLarge(
                actual: frame.metadata.count,
                maximum: ASRWorkerProtocol.maximumMetadataBytes
            )
        }
        guard frame.payload.count <= ASRWorkerProtocol.maximumPCMBytes else {
            throw ASRWireError.payloadTooLarge(
                actual: frame.payload.count,
                maximum: ASRWorkerProtocol.maximumPCMBytes
            )
        }

        var header = Data()
        header.reserveCapacity(headerBytes)
        header.append(contentsOf: magic)
        append(ASRWorkerProtocol.version, to: &header)
        append(frame.kind.rawValue, to: &header)
        append(frame.requestID, to: &header)
        append(UInt32(frame.metadata.count), to: &header)
        append(UInt64(frame.payload.count), to: &header)

        try writeAll(header, to: descriptor)
        try writeAll(frame.metadata, to: descriptor)
        try writeAll(frame.payload, to: descriptor)
    }

    /// `nil` means clean EOF before the next frame. EOF inside a frame is an error.
    public static func read(from descriptor: Int32) throws -> ASRWireFrame? {
        guard let header = try readExactly(headerBytes, from: descriptor, allowsInitialEOF: true) else {
            return nil
        }
        let bytes = [UInt8](header)
        guard Array(bytes[0..<4]) == magic else { throw ASRWireError.invalidMagic }
        let version = uint16(bytes, at: 4)
        guard version == ASRWorkerProtocol.version else {
            throw ASRWireError.protocolMismatch(actual: version)
        }
        let rawKind = uint16(bytes, at: 6)
        guard let kind = ASRWireKind(rawValue: rawKind) else {
            throw ASRWireError.unknownMessageKind(rawKind)
        }
        let requestID = uint64(bytes, at: 8)
        let metadataCount = Int(uint32(bytes, at: 16))
        let payloadCount64 = uint64(bytes, at: 20)
        guard payloadCount64 <= UInt64(Int.max) else {
            throw ASRWireError.payloadTooLarge(actual: Int.max, maximum: ASRWorkerProtocol.maximumPCMBytes)
        }
        let payloadCount = Int(payloadCount64)
        guard metadataCount <= ASRWorkerProtocol.maximumMetadataBytes else {
            throw ASRWireError.metadataTooLarge(
                actual: metadataCount,
                maximum: ASRWorkerProtocol.maximumMetadataBytes
            )
        }
        guard payloadCount <= ASRWorkerProtocol.maximumPCMBytes else {
            throw ASRWireError.payloadTooLarge(
                actual: payloadCount,
                maximum: ASRWorkerProtocol.maximumPCMBytes
            )
        }

        let metadata = try readExactly(metadataCount, from: descriptor, allowsInitialEOF: false) ?? Data()
        let payload = try readExactly(payloadCount, from: descriptor, allowsInitialEOF: false) ?? Data()
        return ASRWireFrame(kind: kind, requestID: requestID, metadata: metadata, payload: payload)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ASRWireError.systemCall(operation: "write", code: errno)
                }
                guard count > 0 else { throw ASRWireError.truncatedFrame }
                offset += count
            }
        }
    }

    private static func readExactly(
        _ count: Int,
        from descriptor: Int32,
        allowsInitialEOF: Bool
    ) throws -> Data? {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress?.advanced(by: offset), count - offset)
            }
            if received == 0 {
                if offset == 0, allowsInitialEOF { return nil }
                throw ASRWireError.truncatedFrame
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw ASRWireError.systemCall(operation: "read", code: errno)
            }
            offset += received
        }
        return Data(bytes)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        bytes[offset..<(offset + 2)].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        bytes[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
