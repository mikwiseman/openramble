import AppKit
import SwiftUI

/// One meaning per color, everywhere in the app.
///
/// Status colors are a vocabulary, not decoration: the same red that fills the
/// menu bar dot fills the overlay's recording indicator, so a person learns
/// each color exactly once. Decorative accents use `Color.accentColor` and
/// never borrow from this table.
///
/// - `recording` — the microphone is capturing. Nothing else may be red.
/// - `processing` — the app is working on speech (transcribing, inserting).
/// - `success` — a good outcome: permission granted, model ready, trial passed.
/// - `attention` — something waits for the person, and their work is preserved.
///   Failures here are recoverable by design, so they wear orange, not a
///   destructive red that would cry wolf.
enum StatusColorRole: CaseIterable, Equatable {
    case recording
    case processing
    case success
    case attention

    var color: Color {
        switch self {
        case .recording: return .red
        case .processing: return .blue
        case .success: return .green
        case .attention: return .orange
        }
    }

    var nsColor: NSColor {
        switch self {
        case .recording: return .systemRed
        case .processing: return .systemBlue
        case .success: return .systemGreen
        case .attention: return .systemOrange
        }
    }
}
