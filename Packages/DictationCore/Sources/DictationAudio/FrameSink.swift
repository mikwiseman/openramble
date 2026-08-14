import Foundation

/// The queue of frames between the audio stream and recording to disk.
///
/// The sound engine calls its callback on its own real-time thread:
/// You can neither wait there nor write to a file. The frame needs to be given somewhere for
/// nanoseconds - and at the same time not losing either the order or the last frames.
///
/// Both requirements came from real defects. Each frame used to go to
/// the disk is a separate task - the order of their execution is not specified by anything, and recording
/// could mix with itself. And the stop closed the file without waiting
/// queues, - the last word disappeared, exactly the one on which the person lets go
/// key.
///
/// The type is separated from the microphone intentionally: this way it can be checked without sound
/// hardware that is not in the test environment.
final class FrameSink: @unchecked Sendable {
    static let defaultCapacity = 64

    private let lock = NSLock()
    private var frames: AsyncStream<[Float]>.Continuation?
    private var drain: Task<Void, Never>?

    /// Start receiving frames.
    ///
    /// Returns a function for the audio stream: it just puts the frame in
    /// queue and returns immediately. One task in a row sorts out the queue -
    /// This is the guarantee of order.
    func start(
        capacity: Int = FrameSink.defaultCapacity,
        onOverflow: @escaping @Sendable () -> Void = {},
        consume: @escaping @Sendable ([Float]) async -> Void
    ) -> @Sendable ([Float]) -> Void {
        precondition(capacity > 0)
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        let overflow = OverflowOnce(run: onOverflow)
        let drain = Task {
            for await samples in stream {
                await consume(samples)
            }
        }

        lock.lock()
        precondition(frames == nil && self.drain == nil, "FrameSink already has an active session")
        frames = continuation
        self.drain = drain
        lock.unlock()

        return { samples in
            if case .dropped = continuation.yield(samples) {
                overflow.fire()
            }
        }
    }

    /// Stop accepting frames and atomically detach this session's drain.
    ///
    /// There is deliberately no `await` before the stored properties are
    /// cleared. An old completion can therefore never erase a drain installed
    /// by another session. Production uses one sink per recording as a second
    /// layer of protection.
    func seal() -> Task<Void, Never> {
        lock.lock()
        let continuation = frames
        let detachedDrain = drain
        frames = nil
        drain = nil
        lock.unlock()

        continuation?.finish()
        return detachedDrain ?? Task {}
    }

    /// Close the queue and wait until the last frame is consumed.
    func finish() async {
        await seal().value
    }

    /// Leave the queue without waiting for the recording - the dictation was cancelled.
    func cancel() {
        lock.lock()
        let continuation = frames
        let detachedDrain = drain
        frames = nil
        drain = nil
        lock.unlock()

        continuation?.finish()
        detachedDrain?.cancel()
    }
}

/// A full bounded queue is one recording failure, not one failure per audio
/// frame. The callback can otherwise enqueue dozens of identical UI tasks
/// before the controller gets a chance to stop the session.
private final class OverflowOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let run: @Sendable () -> Void

    init(run: @escaping @Sendable () -> Void) {
        self.run = run
    }

    func fire() {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        run()
    }
}
