import Foundation

/// The system's memory-pressure tier, as the policy sees it.
enum MemoryPressureTier: Equatable {
    case normal
    case warning
    case critical
}

/// When to give the engine's memory back to the system — automatically.
///
/// Handy asks the user to pick an unload timer from seven options. This is
/// the zero-settings answer: macOS itself says when memory is tight, and the
/// policy reacts — evaluated only on events (a pressure callback, a finished
/// dictation, a finished load, wake), never by polling. Reloading is cheap to
/// the person because it rides under their voice at the next keypress.
///
/// The rules, agreed in three review rounds (Codex + Kimi, both AGREE):
/// - critical pressure and a safely idle engine → unload now; critical
///   overrides the hysteresis (Apple: release as much as possible).
/// - warning pressure must persist (≥2 consecutive events) AND the engine
///   must have been idle ≥5 minutes → unload. One warning blip does nothing.
/// - hysteresis, warning tier only: never unload within 10 minutes of the
///   last completed load — an ambient-pressure machine must not oscillate
///   between 16-second loads and unloads.
/// - there is NO unconditional time-based unload: a healthy machine keeps
///   the engine warm forever, because manufacturing cold starts for a
///   benefit nobody can feel would attack the product's own identity.
enum EngineResidencyPolicy {
    static let warningIdleThreshold: TimeInterval = 300
    static let warningEventsRequired = 2
    static let postLoadHold: TimeInterval = 600

    enum Decision: Equatable {
        case keep
        case unload
        /// A rule is pending a time boundary: re-evaluate after this delay.
        /// The caller arms ONE one-shot timer; at rest there is no timer.
        case checkAgain(after: TimeInterval)
    }

    static func decision(
        tier: MemoryPressureTier,
        consecutiveWarnings: Int,
        engineLoaded: Bool,
        engineBusy: Bool,
        idleFor: TimeInterval,
        sinceLoadCompleted: TimeInterval
    ) -> Decision {
        guard engineLoaded else { return .keep }
        // Never interleave with work; completion events re-evaluate.
        guard !engineBusy else { return .keep }

        switch tier {
        case .critical:
            return .unload

        case .warning:
            guard consecutiveWarnings >= warningEventsRequired else { return .keep }
            let idleReady = idleFor >= warningIdleThreshold
            let holdExpired = sinceLoadCompleted >= postLoadHold
            if idleReady && holdExpired {
                return .unload
            }
            // Waiting on a boundary: come back exactly when the later of the
            // two windows opens.
            let untilIdle = max(0, warningIdleThreshold - idleFor)
            let untilHold = max(0, postLoadHold - sinceLoadCompleted)
            return .checkAgain(after: max(untilIdle, untilHold))

        case .normal:
            return .keep
        }
    }
}
