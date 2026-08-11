import SwiftUI

extension View {
    /// The functional surface used by transient controls and navigation chrome.
    ///
    /// Native Liquid Glass is available on macOS 26. Older supported systems keep
    /// the same hierarchy with the system material instead of a hand-drawn imitation.
    func glassSurface<S: Shape>(_ shape: S) -> some View {
        modifier(GlassSurfaceModifier(shape: shape))
    }

    /// A quiet standard-material card inside the content layer.
    ///
    /// Liquid Glass is reserved for floating controls and navigation. Content
    /// cards use standard material so the hierarchy stays calm and legible.
    func contentSurface<S: Shape>(_ shape: S) -> some View {
        modifier(ContentSurfaceModifier(shape: shape))
    }
}

private struct GlassSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background, in: shape)
                .overlay {
                    shape.stroke(.primary.opacity(borderOpacity), lineWidth: 0.75)
                }
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.stroke(.primary.opacity(borderOpacity), lineWidth: 0.75)
                    }
                }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.stroke(
                        .white.opacity(contrast == .increased ? 0.28 : 0.12),
                        lineWidth: 0.5
                    )
                }
        }
    }

    private var borderOpacity: Double {
        contrast == .increased ? 0.42 : 0.22
    }
}

private struct ContentSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(
                reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial),
                in: shape
            )
            .overlay {
                shape.stroke(
                    .primary.opacity(contrast == .increased ? 0.28 : 0.10),
                    lineWidth: contrast == .increased ? 0.75 : 0.5
                )
            }
    }
}
