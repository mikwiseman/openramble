import DictationCore
import Foundation

/// Hands finished pieces of a running recording to the engine, so the person is
/// not waiting at the end for work that could have happened while they spoke.
///
/// Shaped after `RecordingDiskAttachment` deliberately: it is fed from the same
/// place, inside the sequenced lossless commit, and it must be equally cheap
/// there. `submit` computes one peak and hands an already-owned array to a
/// serial queue — no copy, no file, no lock held across work. Everything that
/// costs anything happens on that queue, off the audio thread.
///
/// The cut rule itself lives in `SpeechSegmenter`, which is pure and tested
/// without a microphone. This type is only the plumbing around it.
final class RecordingSegmentAttachment: @unchecked Sendable {
    /// Its own serial queue, which is also what keeps frames in order.
    ///
    /// `utility` rather than `userInteractive`: nothing here is on the path the
    /// person is waiting on. The whole point is that this work happens early,
    /// so it can afford to yield to the recording and to a dictation that is
    /// actually finishing.
    private let queue = DispatchQueue(
        label: "is.waiwai.dictation.recording-segments",
        qos: .utility
    )

    private let lock = NSLock()
    private var sink: (@Sendable ([Float]) -> Void)?
    private var segmenter: SpeechSegmenter
    /// Audio not yet shipped in a segment.
    private var pending: [Float] = []
    /// How much of the recording has left in completed segments.
    ///
    /// The controller needs exactly this number at freeze: everything past it is
    /// the tail nobody has recognized yet.
    private var consumed = 0
    private var closed = false

    init(segmenter: SpeechSegmenter = SpeechSegmenter()) {
        self.segmenter = segmenter
    }

    /// Where completed segments go. Absent means "do not segment at all", which
    /// is the behaviour every existing caller gets for free.
    func setSink(_ sink: (@Sendable ([Float]) -> Void)?) {
        lock.withLock { self.sink = sink }
    }

    private var hasSink: Bool { lock.withLock { sink != nil } }

    /// Called inside the sequenced lossless commit, on the audio thread.
    ///
    /// Returns immediately. The array is retained, not copied: it is already
    /// owned by the caller's turn and nothing mutates it afterwards.
    func submit(_ samples: [Float]) {
        guard hasSink, !samples.isEmpty else { return }
        queue.async { [self] in ingest(samples) }
    }

    private func ingest(_ samples: [Float]) {
        guard !closed else { return }
        var peak: Float = 0
        for value in samples { peak = max(peak, abs(value)) }

        pending.append(contentsOf: samples)
        guard let cut = segmenter.observe(peak: peak, count: samples.count) else { return }
        // A cut can only be offered for audio already in `pending`, because the
        // segmenter counts exactly the frames handed to it.
        guard cut > 0, cut <= pending.count else { return }

        let segment = Array(pending[0..<cut])
        pending.removeFirst(cut)
        consumed += cut

        let sink = lock.withLock { self.sink }
        sink?(segment)
    }

    /// Everything submitted so far has been processed; how much left in
    /// segments.
    ///
    /// `sync` is the barrier: by the time it returns, every `submit` that
    /// happened before it has run. Freeze calls this so the tail it hands to the
    /// engine begins exactly where the last segment ended, with no frame counted
    /// twice and none dropped between them.
    func drainConsumedSampleCount() -> Int {
        queue.sync {
            closed = true
            return consumed
        }
    }
}
