import Foundation
import Testing

@testable import AgentBridge

@Suite("Length-prefixed frames")
struct FrameCodecTests {
    @Test("A frame survives every byte boundary")
    func fragmented() throws {
        let payload = Data("hello".utf8)
        let encoded = try LengthPrefixedFrameEncoder.encode(payload)

        for split in 0...encoded.count {
            var decoder = LengthPrefixedFrameDecoder()
            var frames = try decoder.append(encoded.prefix(split))
            frames += try decoder.append(encoded.dropFirst(split))
            #expect(frames == [payload])
        }
    }

    @Test("Several frames may arrive in one read")
    func severalFrames() throws {
        let first = Data("one".utf8)
        let second = Data("two".utf8)
        var stream = try LengthPrefixedFrameEncoder.encode(first)
        stream.append(try LengthPrefixedFrameEncoder.encode(second))
        var decoder = LengthPrefixedFrameDecoder()

        #expect(try decoder.append(stream) == [first, second])
    }

    @Test("Empty and oversized frames fail before allocation")
    func bounds() throws {
        var empty = LengthPrefixedFrameDecoder(maximumBytes: 8)
        #expect(throws: FrameCodecError.emptyFrame) {
            try empty.append(Data([0, 0, 0, 0]))
        }

        var oversized = LengthPrefixedFrameDecoder(maximumBytes: 8)
        #expect(throws: FrameCodecError.frameTooLarge(actual: 9, maximum: 8)) {
            try oversized.append(Data([0, 0, 0, 9]))
        }
    }
}
