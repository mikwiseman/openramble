import Foundation

/// Who gets the engine: dictation, always and at once.
///
/// One decode runs at a time, globally, and a meeting produces decodes for
/// an hour. Without a rule the person's own dictation would queue behind a
/// stranger's sentence. The rule is small: while a dictation session is
/// running, meeting decodes do not *start*. The one already running is not
/// cancelled — it is bounded by the segment cap instead, and cancelling
/// would mean editing the dictation-critical adapter for a wait that is
/// already short.
///
/// An engine that is not loaded is nobody's turn either: the queue waits for
/// readiness the same way it waits for dictation to finish.
public actor EngineArbiter {
    private var dictationActive = false
    private var engineReady: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(engineReady: Bool = false) {
        self.engineReady = engineReady
    }

    public var isFree: Bool { !dictationActive && engineReady }

    public func setDictationActive(_ active: Bool) {
        dictationActive = active
        resumeWaitersIfFree()
    }

    public func setEngineReady(_ ready: Bool) {
        engineReady = ready
        resumeWaitersIfFree()
    }

    /// Returns when a meeting decode may start.
    public func awaitMeetingTurn() async {
        if isFree { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeWaitersIfFree() {
        guard isFree else { return }
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
    }
}
