import Foundation

/// Recognizes the pieces of a running take, in the order they were cut.
///
/// Segments arrive from the capture's own queue while the person is still
/// speaking. This type does two things with them and nothing else: it keeps
/// them in order, and it keeps at most one decode in flight — which is not a
/// style choice but the runtime's rule, since only one recognition may run
/// across all sessions of a model.
///
/// **A failed segment does not half-recognize a take.** The first error stops
/// the stream and is reported at the end, so the owner can fall back to
/// recognizing the whole recording the way it always did. Half a transcript
/// silently missing its middle is exactly the failure this project refuses to
/// ship; a slower correct answer is the right trade every time.
public final class StreamedSegmentRecognizer: @unchecked Sendable {
    /// What the stream produced.
    public enum Outcome: Sendable {
        /// Every segment recognized, in order.
        case recognized([String])
        /// A segment failed. Nothing here can be trusted; recognize the whole
        /// take instead. The error is carried so the caller can say why.
        case failed(any Error)
    }

    private let transcribe: @Sendable ([Float]) async throws -> ASRResult
    private let lock = NSLock()
    /// The end of the chain. Each submission waits for the previous one, which
    /// is what keeps both the order and the one-at-a-time rule without a queue
    /// of its own.
    private var tail: Task<Void, Never>?
    /// One entry per segment handed over, in order, including the ones that
    /// recognized as nothing. Kept aligned with `sampleCounts` so the owner can
    /// drop the last segment and re-recognize it with the tail.
    private var texts: [String] = []
    private var sampleCounts: [Int] = []
    private var failure: (any Error)?
    private var stopped = false

    public init(transcribe: @escaping @Sendable ([Float]) async throws -> ASRResult) {
        self.transcribe = transcribe
    }

    /// Hand over one finished segment. Returns immediately.
    ///
    /// Safe to call from the capture's queue: nothing here blocks, and the work
    /// happens on the chained task rather than the caller's thread.
    public func submit(_ samples: [Float]) {
        lock.lock()
        if stopped || failure != nil || samples.isEmpty {
            lock.unlock()
            return
        }
        let previous = tail
        let transcribe = self.transcribe
        sampleCounts.append(samples.count)
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // A failure earlier in the chain makes every later segment
            // pointless: the take is going to be recognized whole regardless.
            guard !self.hasFailed else { return }
            do {
                let result = try await transcribe(samples)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.append(text)
            } catch {
                self.recordFailure(error)
            }
        }
        tail = task
        lock.unlock()
    }

    private var hasFailed: Bool { lock.withLock { failure != nil } }

    private func append(_ text: String) {
        lock.withLock {
            guard failure == nil else { return }
            // Appended even when empty. A segment of pure breath recognizes as
            // nothing, and dropping it here would misalign the transcripts from
            // the sample counts — which is what the owner uses to take the last
            // segment back when the tail turns out too short to stand alone.
            // The blanks are filtered where the pieces are joined.
            texts.append(text)
        }
    }

    private func recordFailure(_ error: any Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    /// Wait for everything submitted so far, and say how it went.
    ///
    /// After this returns, no further submission is accepted — the take is
    /// over, and a segment arriving late would append text after the tail the
    /// caller is about to add.
    public func finish() async -> Outcome {
        // Scoped rather than lock/unlock around the await: `NSLock.lock()` is
        // unavailable from an async context, and holding a lock across a
        // suspension is what it is protecting against.
        let pending: Task<Void, Never>? = lock.withLock {
            stopped = true
            return tail
        }

        await pending?.value

        return lock.withLock {
            if let failure { return .failed(failure) }
            return .recognized(texts)
        }
    }

    /// How many segments have finished. For the speed report, and for tests
    /// that need to know the stream actually ran.
    public var recognizedCount: Int { lock.withLock { texts.count } }

    /// Sample counts of the segments handed over, in order.
    ///
    /// The owner needs the last one: if the person releases the key just after
    /// a cut, the tail can be too short for the decoder to be trusted with, and
    /// the cure is to hand back the last segment and recognize it together with
    /// the tail rather than decode a fragment on its own.
    public var submittedSampleCounts: [Int] { lock.withLock { sampleCounts } }
}
