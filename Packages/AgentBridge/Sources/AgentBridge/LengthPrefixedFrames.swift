import Foundation

public enum FrameCodecError: Error, Equatable, Sendable {
    case emptyFrame
    case frameTooLarge(actual: Int, maximum: Int)
}

/// A four-byte, big-endian length followed by an opaque payload.
///
/// Unlike MCP stdio, the private app/helper connection is a byte stream and
/// needs framing that survives arbitrary `read(2)` fragmentation.
public enum LengthPrefixedFrameEncoder {
    public static func encode(
        _ payload: Data,
        maximumBytes: Int = AgentBridgeProtocol.defaultMaximumFrameBytes
    ) throws -> Data {
        guard !payload.isEmpty else { throw FrameCodecError.emptyFrame }
        guard payload.count <= maximumBytes else {
            throw FrameCodecError.frameTooLarge(actual: payload.count, maximum: maximumBytes)
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }
}

public struct LengthPrefixedFrameDecoder: Sendable {
    private var buffer = Data()
    private var expectedPayloadBytes: Int?
    private let maximumBytes: Int

    public init(maximumBytes: Int = AgentBridgeProtocol.defaultMaximumFrameBytes) {
        precondition(maximumBytes > 0 && maximumBytes <= Int(UInt32.max))
        self.maximumBytes = maximumBytes
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []

        while true {
            if expectedPayloadBytes == nil {
                guard buffer.count >= MemoryLayout<UInt32>.size else { break }
                let length = buffer.prefix(MemoryLayout<UInt32>.size).reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                }
                buffer.removeFirst(MemoryLayout<UInt32>.size)
                guard length > 0 else { throw FrameCodecError.emptyFrame }
                guard length <= UInt32(maximumBytes) else {
                    throw FrameCodecError.frameTooLarge(
                        actual: Int(length),
                        maximum: maximumBytes
                    )
                }
                expectedPayloadBytes = Int(length)
            }

            guard let expectedPayloadBytes, buffer.count >= expectedPayloadBytes else { break }
            frames.append(Data(buffer.prefix(expectedPayloadBytes)))
            buffer.removeFirst(expectedPayloadBytes)
            self.expectedPayloadBytes = nil
        }

        return frames
    }
}
