import SwiftUI

extension View {
    /// The functional surface used by transient controls and navigation chrome.
    ///
    /// Native Liquid Glass is available on macOS 26. Older supported systems keep
    /// the same hierarchy with the system material instead of a hand-drawn imitation.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay {
                    shape.stroke(.white.opacity(0.12), lineWidth: 0.5)
                }
        }
    }
}
