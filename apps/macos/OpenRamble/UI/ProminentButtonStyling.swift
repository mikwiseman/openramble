import SwiftUI

/// The screen's primary button: Liquid Glass on macOS 26, the regular
/// prominent style before it.
///
/// Liquid Glass belongs exactly to the most important controls — one primary
/// button per window. Step content stays glass-free: it is the control layer,
/// not decoration.
extension View {
    @ViewBuilder
    func prominentActionButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
