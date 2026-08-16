import CryptoKit
import Foundation

// CPU-only executable specification for the proposed app <-> worker audio lane.
// It deliberately contains no Core ML imports and cannot load a model.

struct StreamFence: Equatable {
    let workerGeneration: UInt64
    let dictationSession: UUID
    let streamID: UUID
}

struct StreamFrame {
    let fence: StreamFence
    let sequence: UInt64
    let startSample: UInt64
    let pcmF32LE: Data

    var sampleCount: Int { pcmF32LE.count / MemoryLayout<Float>.size }
}

struct StreamFrameAck: Equatable {
    let sequence: UInt64
    let cumulativeOwnedSamples: UInt64
    let remainingQueueSamples: Int
}

enum StreamProtocolFailure: Error, Equatable, CustomStringConvertible {
    case noActiveStream
    case staleFence
    case wrongSequence(expected: UInt64, actual: UInt64)
    case wrongStartSample(expected: UInt64, actual: UInt64)
    case invalidPayloadBytes(Int)
    case frameTooLarge(Int)
    case queueOverflow(maximumSamples: Int)
    case alreadyTerminal
    case finalCountMismatch(expected: UInt64, actual: UInt64)
    case finalHashMismatch

    var description: String {
        switch self {
        case .noActiveStream: return "no_active_stream"
        case .staleFence: return "stale_fence"
        case let .wrongSequence(expected, actual): return "wrong_sequence_\(expected)_\(actual)"
        case let .wrongStartSample(expected, actual): return "wrong_start_\(expected)_\(actual)"
        case let .invalidPayloadBytes(bytes): return "invalid_payload_bytes_\(bytes)"
        case let .frameTooLarge(samples): return "frame_too_large_\(samples)"
        case let .queueOverflow(maximumSamples): return "queue_overflow_\(maximumSamples)"
        case .alreadyTerminal: return "already_terminal"
        case let .finalCountMismatch(expected, actual): return "final_count_\(expected)_\(actual)"
        case .finalHashMismatch: return "final_hash_mismatch"
        }
    }
}

final class BoundedStreamInbox {
    static let maximumFrameSamples = 1_280       // 80 ms at 16 kHz
    static let maximumQueuedSamples = 81_920     // 5.12 s / 327,680 payload bytes

    private enum State {
        case idle
        case open
        case invalid(StreamProtocolFailure)
        case finished
    }

    private var state: State = .idle
    private var fence: StreamFence?
    private var nextSequence: UInt64 = 0
    private var ownedSamples: UInt64 = 0
    private var queuedSamples = 0
    private var frames: [StreamFrame] = []
    private var hasher = SHA256()

    func open(_ fence: StreamFence) throws {
        switch state {
        case .idle, .finished:
            break
        case .open, .invalid:
            throw StreamProtocolFailure.alreadyTerminal
        }
        state = .open
        self.fence = fence
        nextSequence = 0
        ownedSamples = 0
        queuedSamples = 0
        frames.removeAll(keepingCapacity: true)
        hasher = SHA256()
    }

    // ACK means the worker owns an immutable PCM copy in this bounded queue.
    // It does not mean inference has completed.
    func accept(_ frame: StreamFrame) throws -> StreamFrameAck {
        guard case .open = state, let activeFence = fence else {
            if case let .invalid(reason) = state { throw reason }
            throw StreamProtocolFailure.noActiveStream
        }
        guard frame.fence == activeFence else { throw invalidate(.staleFence) }
        guard frame.sequence == nextSequence else {
            throw invalidate(.wrongSequence(expected: nextSequence, actual: frame.sequence))
        }
        guard frame.startSample == ownedSamples else {
            throw invalidate(.wrongStartSample(expected: ownedSamples, actual: frame.startSample))
        }
        guard !frame.pcmF32LE.isEmpty,
              frame.pcmF32LE.count.isMultiple(of: MemoryLayout<Float>.size)
        else {
            throw invalidate(.invalidPayloadBytes(frame.pcmF32LE.count))
        }
        guard frame.sampleCount <= Self.maximumFrameSamples else {
            throw invalidate(.frameTooLarge(frame.sampleCount))
        }
        guard queuedSamples + frame.sampleCount <= Self.maximumQueuedSamples else {
            throw invalidate(.queueOverflow(maximumSamples: Self.maximumQueuedSamples))
        }

        // Data is a value type; the accepted value is retained until the consumer takes it.
        frames.append(frame)
        queuedSamples += frame.sampleCount
        ownedSamples += UInt64(frame.sampleCount)
        nextSequence += 1
        hasher.update(data: frame.pcmF32LE)
        return StreamFrameAck(
            sequence: frame.sequence,
            cumulativeOwnedSamples: ownedSamples,
            remainingQueueSamples: Self.maximumQueuedSamples - queuedSamples
        )
    }

    @discardableResult
    func consumeOne() -> StreamFrame? {
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        queuedSamples -= frame.sampleCount
        return frame
    }

    func finish(finalSampleCount: UInt64, finalPCMHashHex: String) throws {
        guard case .open = state else {
            if case let .invalid(reason) = state { throw reason }
            throw StreamProtocolFailure.noActiveStream
        }
        guard finalSampleCount == ownedSamples else {
            throw invalidate(.finalCountMismatch(expected: ownedSamples, actual: finalSampleCount))
        }
        let copy = hasher
        let actual = copy.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == finalPCMHashHex else { throw invalidate(.finalHashMismatch) }
        state = .finished
    }

    private func invalidate(_ failure: StreamProtocolFailure) -> StreamProtocolFailure {
        state = .invalid(failure)
        return failure
    }
}

private func pcm(_ sampleCount: Int, salt: UInt8) -> Data {
    Data((0..<(sampleCount * MemoryLayout<Float>.size)).map { UInt8($0 & 0xff) ^ salt })
}

private func hash(_ pieces: [Data]) -> String {
    var hasher = SHA256()
    for piece in pieces { hasher.update(data: piece) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func expectFailure(
    _ expected: StreamProtocolFailure,
    _ body: () throws -> Void,
    file: StaticString = #file,
    line: UInt = #line
) {
    do {
        try body()
        preconditionFailure("expected \(expected)", file: file, line: line)
    } catch let actual as StreamProtocolFailure {
        precondition(actual == expected, "expected \(expected), got \(actual)", file: file, line: line)
    } catch {
        preconditionFailure("unexpected error \(error)", file: file, line: line)
    }
}

private func makeFence(_ generation: UInt64 = 7) -> StreamFence {
    StreamFence(
        workerGeneration: generation,
        dictationSession: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        streamID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )
}

private func runTests() throws {
    // Happy path: two complete 80 ms frames and one final partial frame.
    do {
        let inbox = BoundedStreamInbox()
        let fence = makeFence()
        try inbox.open(fence)
        let pieces = [pcm(1_280, salt: 1), pcm(1_280, salt: 2), pcm(317, salt: 3)]
        var start: UInt64 = 0
        for (sequence, piece) in pieces.enumerated() {
            let ack = try inbox.accept(StreamFrame(
                fence: fence,
                sequence: UInt64(sequence),
                startSample: start,
                pcmF32LE: piece
            ))
            start = ack.cumulativeOwnedSamples
        }
        try inbox.finish(finalSampleCount: start, finalPCMHashHex: hash(pieces))
    }

    // Sequence gaps invalidate the whole speculative candidate.
    do {
        let inbox = BoundedStreamInbox(); let fence = makeFence()
        try inbox.open(fence)
        expectFailure(.wrongSequence(expected: 0, actual: 1)) {
            _ = try inbox.accept(StreamFrame(fence: fence, sequence: 1, startSample: 0, pcmF32LE: pcm(1, salt: 1)))
        }
        expectFailure(.wrongSequence(expected: 0, actual: 1)) {
            _ = try inbox.accept(StreamFrame(fence: fence, sequence: 0, startSample: 0, pcmF32LE: pcm(1, salt: 1)))
        }
    }

    // Absolute sample offsets bind ordering even if sequence metadata is forged.
    do {
        let inbox = BoundedStreamInbox(); let fence = makeFence()
        try inbox.open(fence)
        expectFailure(.wrongStartSample(expected: 0, actual: 80)) {
            _ = try inbox.accept(StreamFrame(fence: fence, sequence: 0, startSample: 80, pcmF32LE: pcm(1, salt: 2)))
        }
    }

    // A stale worker/session/stream generation is never admitted.
    do {
        let inbox = BoundedStreamInbox(); try inbox.open(makeFence())
        expectFailure(.staleFence) {
            _ = try inbox.accept(StreamFrame(fence: makeFence(8), sequence: 0, startSample: 0, pcmF32LE: pcm(1, salt: 3)))
        }
    }

    // Exactly 64 x 1280 samples fit; the next frame hard-fails rather than drops.
    do {
        let inbox = BoundedStreamInbox(); let fence = makeFence()
        try inbox.open(fence)
        for sequence in 0..<64 {
            _ = try inbox.accept(StreamFrame(
                fence: fence,
                sequence: UInt64(sequence),
                startSample: UInt64(sequence * 1_280),
                pcmF32LE: pcm(1_280, salt: UInt8(sequence))
            ))
        }
        expectFailure(.queueOverflow(maximumSamples: 81_920)) {
            _ = try inbox.accept(StreamFrame(
                fence: fence,
                sequence: 64,
                startSample: 81_920,
                pcmF32LE: pcm(1, salt: 64)
            ))
        }
    }

    // Finish binds the exact complete PCM, not merely frame counts.
    do {
        let inbox = BoundedStreamInbox(); let fence = makeFence()
        try inbox.open(fence)
        let piece = pcm(10, salt: 9)
        _ = try inbox.accept(StreamFrame(fence: fence, sequence: 0, startSample: 0, pcmF32LE: piece))
        expectFailure(.finalHashMismatch) {
            try inbox.finish(finalSampleCount: 10, finalPCMHashHex: String(repeating: "0", count: 64))
        }
    }

    print("{\"cpu_protocol_tests\":6,\"status\":\"pass\",\"max_frame_samples\":1280,\"max_queued_samples\":81920}")
}

try runTests()
