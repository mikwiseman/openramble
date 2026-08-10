import DictationCore
import Foundation

/// The line “stop → text: N ms” in the panel.
///
/// Pure type like `OverlayContent` and `ModelStatus`: number formatting -
/// this is a rule, not a layout, and is checked without a panel and without a model.
///
/// The **second** mark is displayed - “⌘V sent”. She is more honest than others:
/// the first (the engine returned the text) does not mean that the person already has the text, but the third
/// includes a buffer protection second, i.e. waiting, not working.
struct SpeedReadout: Equatable {
    let line: String
    /// For VoiceOver - in words: “ms” the synthesizer reads as “emes”.
    let accessibilityLabel: String

    /// `nil` if no one measured the insertion. It's better not to show anything than
    /// show the number that was calculated for the wrong reason.
    static func make(_ report: DictationSpeedReport) -> SpeedReadout? {
        guard let dispatched = report.toPasteDispatched else { return nil }

        let milliseconds = dispatched.components.seconds * 1000
            + dispatched.components.attoseconds / 1_000_000_000_000_000
        // Floor in one millisecond: “0 ms” - not fast, but immeasurable, and read
        // as if it were a deliberate lie.
        let clamped = max(1, milliseconds)

        if clamped < 1000 {
            return SpeedReadout(
                line: "stop → text: \(clamped) ms",
                accessibilityLabel: "Text ready \(clamped) milliseconds after you released the key"
            )
        }
        let seconds = Double(clamped) / 1000
        let text = String(format: "%.1f", seconds)
        return SpeedReadout(
            line: "stop → text: \(text) s",
            accessibilityLabel: "Text ready \(text) seconds after you released the key"
        )
    }
}
