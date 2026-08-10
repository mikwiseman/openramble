import Foundation

/// What to show while the engine is preparing for the first dictation.
///
/// The first launch after installation was silent for 12–15 seconds: macOS compiles the model
/// under the Neural Engine, and all this time the person did not understand whether something was broken.
///
/// **There is no interest here and there never will be.** There is no ANE compilation progress signal
/// exists - neither the system nor the library. The drawn stripe would be
/// fiction, and fictional progress is worse than honest silence: it promises a deadline,
/// which no one knows. We show the elapsed seconds and explain the reason.
///
/// Engine failure is not included here intentionally: it already has an owner -
/// `ModelStatus.repairRequired`. The second type about the same thing would be a double,
/// which sooner or later will break up with the first.
public struct EnginePreparationState: Equatable {
    public enum Phase: Equatable {
        case idle
        case loadingRecognizer
        case loadingVocabulary
        case ready
    }

    public let phase: Phase
    public let elapsed: TimeInterval
    public let title: String
    public let detail: String?

    public static func make(phase: Phase, elapsed: TimeInterval) -> EnginePreparationState {
        let seconds = Int(elapsed.rounded())
        switch phase {
        case .idle:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: "Model not prepared",
                detail: nil
            )
        case .loadingRecognizer:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: "Preparing the recognizer… \(seconds) s",
                // The formulation is correct both on a cold and on a warm start, so
                // branches are not needed and the promise cannot be broken.
                detail: "macOS is compiling the model for the Neural Engine. Up to about "
                    + "20 seconds the first time after install, a fraction of a second "
                    + "afterwards. There is no progress to show — the seconds are real."
            )
        case .loadingVocabulary:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: "Preparing the term booster… \(seconds) s",
                detail: "A second, smaller model. Same one-time compile."
            )
        case .ready:
            return EnginePreparationState(
                phase: phase, elapsed: elapsed,
                title: "Ready to dictate",
                detail: nil
            )
        }
    }
}
