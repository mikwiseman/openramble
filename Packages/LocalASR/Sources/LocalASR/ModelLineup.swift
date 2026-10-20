import Foundation

/// Which installed model recognizes speech while the app moves to a newer one.
///
/// The app ships one current model and remembers the one it replaced. A Mac
/// that already holds the previous model keeps dictating with it after an
/// update; the current model is offered, downloaded only when the person asks,
/// and used from the moment it verifies. Only then is the previous copy
/// removed, so there is never a moment without a working model and never two
/// copies kept for longer than the switch takes.
public struct ModelLineup: Sendable, Equatable {
    public enum Slot: Sendable, Equatable {
        case current
        case previous
        case none
    }

    /// The model recognition loads, or `.none` when nothing usable is installed.
    public let recognizer: Slot
    /// Whether to show the current model as an available upgrade.
    public let offersUpgrade: Bool
    /// Whether the previous model's files should be deleted now.
    public let removesPrevious: Bool
    /// What an install button fetches: always the current model.
    public let installs: Slot = .current

    public init(current: ModelState, previous: ModelState) {
        let previousUsable = previous.isReady
        if current.isReady {
            recognizer = .current
            offersUpgrade = false
            removesPrevious = previous.isReady || previous.requiresRepair || Self.isFailed(previous)
            return
        }
        recognizer = previousUsable ? .previous : .none
        // An upgrade is only an offer while the old model still works; without
        // one, installing the current model is the ordinary first-run path.
        offersUpgrade = previousUsable && Self.canStart(current)
        // A damaged old copy is never repaired, only replaced by the current
        // model, so it is cleared as soon as nothing depends on it.
        removesPrevious = !previousUsable && (previous.requiresRepair || Self.isFailed(previous))
            && current != .deleting
    }

    private static func canStart(_ state: ModelState) -> Bool {
        switch state {
        case .notInstalled, .failed, .repairRequired: true
        case .downloading, .verifying, .ready, .deleting: false
        }
    }

    private static func isFailed(_ state: ModelState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
