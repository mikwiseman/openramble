import AppKit
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
                        .primary.opacity(contrast == .increased ? 0.28 : 0.12),
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

extension View {
    /// The window's own background material.
    ///
    /// On macOS 26 this is the real thing — `.glassEffect` sampling what is
    /// behind the window rather than a fill that looks like it might be. Below
    /// that, the system's own window material, which is what Liquid Glass
    /// replaced and still the right answer there.
    ///
    /// Applied to the window rather than to each box inside it, because the
    /// guidance is explicit that glass belongs to the surface floating above
    /// content and that stacking it is what makes an interface feel cluttered.
    func glassWindowBackground() -> some View {
        modifier(GlassWindowBackground())
    }

    /// A group of related settings.
    ///
    /// Deliberately not glass. Putting glass inside glass is the one thing the
    /// material's own guidance rules out, and a settings pane is content: it
    /// wants separation and calm, not another layer of depth competing with the
    /// window it sits in.
    func settingsGroup() -> some View {
        modifier(SettingsGroup())
    }
}

private struct GlassWindowBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            // "Reduced Transparency makes Liquid Glass frostier and obscures
            // more of the content behind it." At its limit that is opaque.
            content.background(.background)
        } else {
            content.background(WindowMaterial())
        }
    }
}

/// The window's material, straight from AppKit.
///
/// SwiftUI has no way to say "make the window itself vibrant", so this is the
/// one small bridge: an `NSVisualEffectView` behind the whole hierarchy. It is
/// public API and has been since 10.14.
private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // The material made for a window's background, which keeps sampling the
        // desktop instead of freezing when the window loses focus.
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct SettingsGroup: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(GlassTokens.Space.stack)
            .background(
                .quaternary.opacity(0.4),
                in: RoundedRectangle(cornerRadius: GlassTokens.Radius.surface, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: GlassTokens.Radius.surface, style: .continuous)
                    .stroke(
                        .primary.opacity(GlassTokens.Stroke.opacity(increasedContrast: contrast == .increased)),
                        lineWidth: contrast == .increased
                            ? GlassTokens.Stroke.emphasised
                            : GlassTokens.Stroke.hairline
                    )
            }
    }
}

extension View {
    /// A control that floats on the material: buttons, pickers, the things a
    /// person actually presses.
    ///
    /// This is where Liquid Glass belongs and where macOS 26 puts it itself —
    /// system controls are glass on that release. Below it, the same shape in
    /// the system's thin material, so the hierarchy is identical and only the
    /// substance differs.
    func glassControl() -> some View {
        modifier(GlassControl())
    }
}

private struct GlassControl: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlassTokens.Radius.control, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: shape).overlay { border }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape).overlay { border }
        } else {
            content.background(.thinMaterial, in: shape).overlay { border }
        }
    }

    @ViewBuilder
    private var border: some View {
        if contrast == .increased {
            shape.stroke(.primary.opacity(0.42), lineWidth: GlassTokens.Stroke.emphasised)
        }
    }
}
