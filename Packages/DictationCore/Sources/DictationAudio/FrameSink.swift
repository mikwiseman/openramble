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
actor FrameSink {
    private var frames: AsyncStream<[Float]>.Continuation?
    private var drain: Task<Void, Never>?

    /// Start receiving frames.
    ///
    /// Returns a function for the audio stream: it just puts the frame in
    /// queue and returns immediately. One task in a row sorts out the queue -
    /// This is the guarantee of order.
    func start(consume: @escaping @Sendable ([Float]) async -> Void) -> @Sendable ([Float]) -> Void {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        frames = continuation
        drain = Task {
            for await samples in stream {
                await consume(samples)
            }
        }
        return { samples in continuation.yield(samples) }
    }

    /// Close the queue and wait until the last frame is on disk.
    func finish() async {
        frames?.finish()
        frames = nil
        await drain?.value
        drain = nil
    }

    /// Leave the queue without waiting for the recording - the dictation was cancelled.
    func cancel() {
        frames?.finish()
        frames = nil
        drain?.cancel()
        drain = nil
    }
}
