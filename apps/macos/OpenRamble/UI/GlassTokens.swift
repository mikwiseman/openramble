import SwiftUI

/// The visual vocabulary both platforms share.
///
/// Windows and Linux draw their interface in a web view and macOS draws it in
/// SwiftUI, so the two cannot share rendering code — and should not. Apple's own
/// material samples the desktop behind the window in a way no stylesheet can
/// imitate, and forcing one implementation onto both would mean giving that up
/// to match a picture of it.
///
/// What they do share is the intent: the same corner radii, the same spacing
/// rhythm, the same rule about where glass belongs. These are those numbers, and
/// `apps/desktop/ui/index.html` carries the same ones as CSS custom properties.
/// When one changes, both change.
enum GlassTokens {
    /// Corner radii. Concentric: a control inside a surface uses the smaller one
    /// so their curves stay parallel rather than fighting.
    enum Radius {
        static let surface: CGFloat = 18
        static let control: CGFloat = 10
        static let chip: CGFloat = 7
    }

    /// The spacing rhythm. One scale, so nothing is nudged by eye.
    enum Space {
        static let tight: CGFloat = 6
        static let inline: CGFloat = 10
        static let stack: CGFloat = 16
        static let section: CGFloat = 24
        static let page: CGFloat = 28
    }

    /// Hairlines and strokes.
    ///
    /// Weights rather than colours: the colour comes from `.primary` at these
    /// opacities, so it follows the system's light and dark automatically.
    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let emphasised: CGFloat = 0.75

        static func opacity(increasedContrast: Bool) -> Double {
            // "Increased Contrast makes elements predominantly black or white
            // and highlights them with a contrasting border."
            increasedContrast ? 0.42 : 0.12
        }
    }

    /// Type sizes for the small labels that head a section.
    enum Label {
        static let sectionHeader: CGFloat = 11
        static let footnote: CGFloat = 11.5
    }
}
