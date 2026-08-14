import Foundation

/// The system's memory-pressure tier, as the policy sees it.
enum MemoryPressureTier: Equatable {
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
