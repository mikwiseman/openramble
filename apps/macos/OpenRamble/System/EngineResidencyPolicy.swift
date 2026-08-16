import Foundation

/// The system's memory-pressure tier, as the policy sees it.
public enum MemoryPressureTier: Equatable, Sendable {
    case normal
    case warning
    case critical
}

/// When to give the engine's memory back to the system — automatically.
///
/// The recognizer is the product's latency-critical working set. Warning
/// pressure is advisory and must never manufacture a multi-second cold start;
/// only critical pressure can evict a safely idle engine. When pressure later
/// returns to normal, the owner proactively restores full readiness instead of
/// charging the next dictation for the reload.
enum EngineResidencyPolicy {
    enum Decision: Equatable {
        case keep
        case unload
    }

    static func decision(
        tier: MemoryPressureTier,
        engineLoaded: Bool,
        engineBusy: Bool
    ) -> Decision {
        guard engineLoaded else { return .keep }
        // Never interleave with work; completion events re-evaluate.
        guard !engineBusy else { return .keep }

        switch tier {
        case .critical:
            return .unload
        case .warning, .normal:
            return .keep
        }
    }
}

/// When to proactively restore readiness after an eviction.
///
/// A 16 GB machine under real load often never reports `.normal` again, so
/// waiting for it left the engine cold until the next keypress — exactly the
/// moment a reload hurts. Warning-tier pressure earns one settle window
/// instead; critical pressure never rewarms proactively.
public enum EngineRewarmPolicy {
    /// The production settle window; injectable in tests through the
    /// environment so suites never sleep production-scale intervals.
    public static let defaultSettleWindow: Duration = .seconds(10)

    /// `nil` — do not rewarm at this tier; `.zero` — immediately; positive —
    /// wait out one settle window (a newer pressure event replaces it), then
    /// rewarm unless the tier turned critical meanwhile.
    static func settleDelay(
        after tier: MemoryPressureTier,
        settleWindow: Duration = defaultSettleWindow
    ) -> Duration? {
        switch tier {
        case .normal: return .zero
        case .warning: return settleWindow
        case .critical: return nil
        }
    }

    enum RewarmTrigger {
        case keyDown
        case appActivation
    }

    /// The keypress expresses intent and always warms — the reload rides
    /// under the voice either way. App activation is only a hint and stays
    /// polite under critical pressure.
    static func allowsEarlyRewarm(
        trigger: RewarmTrigger,
        tier: MemoryPressureTier
    ) -> Bool {
        switch trigger {
        case .keyDown: return true
        case .appActivation: return tier != .critical
        }
    }
}

/// Whether a crashed worker may respawn right now.
///
/// Without this, jetsam killing the worker under starvation round-trips a
/// 2.4 GB respawn straight back into the same starvation.
enum WorkerRecoveryBackoffPolicy {
    enum Decision: Equatable {
        case proceed
        case deferRespawn(recheckAfter: Duration)
    }

    /// `jitterUnit` ∈ [0, 1): critical pressure defers 5–10 s, jittered so
    /// several waiters do not re-inflate in lockstep.
    static func decision(tier: MemoryPressureTier, jitterUnit: Double) -> Decision {
        switch tier {
        case .critical:
            let clamped = min(max(jitterUnit, 0), 1)
            return .deferRespawn(
                recheckAfter: .milliseconds(5_000 + Int(5_000 * clamped))
            )
        case .warning, .normal:
            return .proceed
        }
    }
}

/// The most recent OS-reported pressure tier, readable from any isolation.
///
/// The supervisor's recovery loop runs off the main actor; it needs the tier
/// without hopping through AppState.
public final class MemoryPressureGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTier: MemoryPressureTier = .normal

    public init() {}

    public var tier: MemoryPressureTier {
        lock.lock()
        defer { lock.unlock() }
        return storedTier
    }

    public func update(_ tier: MemoryPressureTier) {
        lock.lock()
        defer { lock.unlock() }
        storedTier = tier
    }
}
