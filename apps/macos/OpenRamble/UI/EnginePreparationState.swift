import Foundation

/// What to show while the engine is preparing for the first dictation.
///
/// The first launch after installation is a wait of several seconds while macOS builds the
/// model's GPU code for this Mac, and a silent wait reads as something broken.
///
/// **No invented percentage, ever.** Neither the system nor the runtime reports progress inside
/// that build, so a smoothly filling bar would be fiction, and fictional progress is worse than
/// honest silence: it promises a deadline nobody knows.
///
/// What is real is the sequence. Preparation is two genuine milestones — loading the recognizer
/// and a real warm-up inference — and each one completing is a fact the app observes. So the bar
/// advances by completed steps and stands still inside a step, next to seconds that keep moving.
/// A person sees where they are without being told a number that was made up.
///
/// Engine failure is not included here intentionally: it already has an owner -
/// `ModelStatus.repairRequired`. The second type about the same thing would be a double,
/// which sooner or later will break up with the first.
public struct EnginePreparationState: Equatable {
    public enum Phase: Equatable {
        case idle
        case loadingRecognizer
        case warmingUp
        case ready
    }

    /// How many milestones preparation has. Shown as "Step N of 2".
    public static let stepCount = 2

    public let phase: Phase
    public let elapsed: TimeInterval
    public let title: String
    public let detail: String?

    /// Which milestone is running, 1-based. Idle has not started one yet and
    /// ready has finished them all; both clamp into range so the label is
    /// always sayable.
    public var step: Int {
        switch phase {
        case .idle: return 1
        case .loadingRecognizer: return 1
        case .warmingUp: return 2
        case .ready: return Self.stepCount
        }
    }

    public static func make(phase: Phase, elapsed: TimeInterval) -> EnginePreparationState {
        let seconds = Int(elapsed.rounded())
        switch phase {
        case .idle:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: L10n.tr("Model not prepared"),
                detail: nil
            )
        case .loadingRecognizer:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: L10n.tr("Loading the recognizer… %@ s", String(describing: seconds)),
                // The formulation is correct both on a cold and on a warm start, so
                // branches are not needed and the promise cannot be broken.
                detail: L10n.tr("macOS is compiling the model for this Mac. Up to about ")
                    + L10n.tr("20 seconds the first time after install, a fraction of a second ")
                    + L10n.tr("afterwards.")
            )
        case .warmingUp:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: L10n.tr("Warming up recognition… %@ s", String(describing: seconds)),
                detail: L10n.tr("One silent recognition, so your first real dictation is fast.")
            )
        case .ready:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: L10n.tr("Ready to dictate"),
                detail: nil
            )
        }
    }
}
