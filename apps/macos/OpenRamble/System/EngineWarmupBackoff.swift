import Foundation

/// How long to wait before trying the model preparation again.
///
/// Preparation has no alternative: without a warm recognizer there is no
/// product, and the files on disk are already verified. So an attempt that
/// fails is not a verdict the person has to act on — it is one more attempt
/// pending. The app keeps trying for as long as it is open, backing off so a
/// busy machine is not hammered, and the interface simply keeps saying
/// "preparing" instead of manufacturing an error state with a button.
///
/// The ladder matters more than any single value: the first attempts are for
/// a transient hiccup (a Mac still flushing 586 MB it just wrote), the tail is
/// for a machine that is genuinely busy right now and will be free later.
enum EngineWarmupBackoff {
    static let ladder: [Duration] = [
        .seconds(1),
        .seconds(2),
        .seconds(5),
        .seconds(10),
        .seconds(30),
    ]

    /// `attempt` counts failures so far, starting at zero.
    static func delay(afterFailures attempt: Int) -> Duration {
        guard attempt > 0 else { return ladder[0] }
        return ladder[min(attempt, ladder.count - 1)]
    }
}
