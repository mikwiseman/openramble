import Foundation

/// When to give up on a preparation phase: on a genuine stall, never on
/// slowness.
///
/// A first Core ML/ANE specialization is heavy CPU work of machine-dependent
/// length; a call wedged on a dead system service sits at roughly zero CPU.
/// Time alone cannot tell a slow Mac from a broken one — every fixed deadline
/// eventually betrays one of them — so the watchdog watches the worker's
/// cumulative CPU time instead: any burn is progress, a long windless stretch
/// is a wedge. The phase deadline remains only as a far ceiling for the
/// pathological spin that burns CPU forever without finishing.
struct PreparationStallPolicy: Sendable {
    /// No measurable CPU burn for this long means the native call is wedged.
    /// Matches the pre-0.8 fixed deadline's reaction time for real wedges.
    var stallWindow: Duration = .seconds(30)
    /// Burn smaller than this between samples is noise, not work.
    var minimumProgress: Duration = .milliseconds(50)
    /// How often the worker's CPU time is sampled while a phase runs.
    var sampleInterval: Duration = .seconds(5)

    enum Verdict: Equatable {
        case keepWaiting
        case wedged
    }

    func verdict(elapsedSinceProgress: Duration) -> Verdict {
        elapsedSinceProgress >= stallWindow ? .wedged : .keepWaiting
    }

    /// The cadence never exceeds half the phase ceiling, so tests that inject
    /// tiny ceilings keep their prompt kills and production keeps its calm
    /// five-second pulse.
    func effectiveSampleInterval(ceiling: Duration) -> Duration {
        min(sampleInterval, ceiling / 2)
    }
}
