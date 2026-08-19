import SwiftUI

/// The visual vocabulary shared with the Windows and Linux interface.
///
/// Generated from design/tokens.json by scripts/generate-tokens.py. Do not edit.
///
/// The two platforms render differently on purpose — only native code can call
/// Apple's Liquid Glass, which samples and refracts the desktop behind the
/// window — but the geometry and rhythm are one decision, made once.
enum GlassTokens {
    /// Concentric radii: a control inside a surface takes the smaller one so
    /// their curves stay parallel rather than fighting.
    enum Radius {
        static let surface: CGFloat = 18
        static let control: CGFloat = 10
        static let chip: CGFloat = 7
    }

    /// One spacing rhythm, so nothing is nudged by eye.
    enum Space {
        static let tight: CGFloat = 6
        static let inline: CGFloat = 10
        static let stack: CGFloat = 16
        static let section: CGFloat = 24
        static let page: CGFloat = 28
    }

    /// Weights, not colours: the colour comes from the system label, so it
    /// follows light and dark by itself.
    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let emphasised: CGFloat = 0.75

        /// "Increased Contrast makes elements predominantly black or white and
        /// highlights them with a contrasting border."
        static func opacity(increasedContrast: Bool) -> Double {
            increasedContrast ? 0.42 : 0.12
        }
    }

    enum Label {
        static let sectionHeader: CGFloat = 11
        static let footnote: CGFloat = 11.5
    }

    /// Durations. Reduced Motion turns these to zero rather than shortening them.
    enum Motion {
        static let controlFeedback: Double = 120 / 1000
        static let surfaceChange: Double = 150 / 1000
    }
}
