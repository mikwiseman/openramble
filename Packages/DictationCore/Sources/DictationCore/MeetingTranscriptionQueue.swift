import Foundation

/// Decodes the segments of a recording, one at a time, in the order each
/// channel produced them — and keeps going when one fails.
///
/// Holds no audio. A submission is a `MeetingSegmentRef`, and the samples are
/// read back from the file when the decode's turn comes, so a backlog of a
/// hundred segments behind a dictation costs a few kilobytes rather than a
/// hundred megabytes. That is the whole reason the transcript is a
/// projection over the WAV.
///
/// Not `StreamedSegmentRecognizer`: its first failure stops the stream and
/// asks the owner to re-decode the whole take, which is right for twenty
/// seconds and catastrophic for ninety minutes. Here a failed decode becomes
/// one failed paragraph and the next segment proceeds. Three failures in a
/// row pause the queue — something is wrong with the engine, not the audio —
/// and hold what follows until someone asks to resume.
public actor MeetingTranscriptionQueue {
    public enum Outcome: Sendable, Equatable {
        case decoded(text: String)
        case failed(String)
    }

    public typealias Read = @Sendable (MeetingSegmentRef) throws -> [Float]
    public typealias Decode = @Sendable ([Float]) async throws -> String
    public typealias AwaitTurn = @Sendable () async -> Void
    public typealias Emit = @Sendable (MeetingSegmentRef, Outcome) async -> Void

    public static let failuresBeforePause = 3

    private let read: Read
    private let decode: Decode
    private let awaitTurn: AwaitTurn
    private let emit: Emit
    private let sampleRate: Int
    private let deadline: @Sendable (TimeInterval) -> Duration

    private var tail: Task<Void, Never>?
    private var pending = 0
    private var held: [MeetingSegmentRef] = []
    private var consecutiveFailures = 0
    public private(set) var isPaused = false
    /// The end of the last decoded segment per channel — where a relaunch
    /// would resume.
    public private(set) var decodedFrames: [MeetingChannel: Int] = [:]

    /// - Parameters:
    ///   - deadline: how long a decode may take, given the segment's seconds.
    ///     Generous because nobody is waiting for it, bounded because a wedged
    ///     engine must not stall the queue forever.
    public init(
        sampleRate: Int = 16_000,
        read: @escaping Read,
        decode: @escaping Decode,
        awaitTurn: @escaping AwaitTurn,
        emit: @escaping Emit,
        deadline: @escaping @Sendable (TimeInterval) -> Duration = { .seconds(max(60, $0 * 8)) }
    ) {
        self.sampleRate = sampleRate
        self.read = read
        self.decode = decode
        self.awaitTurn = awaitTurn
        self.emit = emit
        self.deadline = deadline
    }

    /// Segments submitted and not yet finished.
    public var backlog: Int { pending + held.count }

    public func submit(_ segment: MeetingSegmentRef) {
        guard segment.frameCount > 0 else { return }
        if isPaused {
            held.append(segment)
            return
        }
        enqueue(segment)
    }

    /// Take the held segments up again after failures paused the queue.
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        consecutiveFailures = 0
        let resumed = held
        held = []
        for segment in resumed { enqueue(segment) }
    }

    /// Wait for everything submitted so far.
    public func drain() async {
        while let task = tail {
            await task.value
            if tail == task { break }
        }
    }

    private func enqueue(_ segment: MeetingSegmentRef) {
        pending += 1
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.process(segment)
        }
    }

    private func process(_ segment: MeetingSegmentRef) async {
        defer { pending -= 1 }
        if isPaused {
            held.append(segment)
            return
        }
        await awaitTurn()
        let seconds = Double(segment.frameCount) / Double(sampleRate)
        let outcome: Outcome
        do {
            let samples = try read(segment)
            let text = try await Self.withDeadline(deadline(seconds)) { [decode] in
                try await decode(samples)
            }
            outcome = .decoded(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            consecutiveFailures = 0
        } catch {
            outcome = .failed(String(describing: error))
            consecutiveFailures += 1
            if consecutiveFailures >= Self.failuresBeforePause { isPaused = true }
        }
        decodedFrames[segment.channel] = max(decodedFrames[segment.channel] ?? 0, segment.endFrame)
        await emit(segment, outcome)
    }

    struct TimedOut: Error {}

    private static func withDeadline<T: Sendable>(
        _ limit: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw TimedOut()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
