import AppKit
import SwiftUI

/// The parts every OpenRamble surface is built from.
///
/// One idea, two layers. Floating pieces — the take block, the recording
/// block — are a rim of Liquid Glass around an opaque slip, so glass frames
/// the words and never carries them. Inside a window a block is content: a
/// flat fill one step from the background, sized by what it holds.

// MARK: - Floating block

extension View {
    /// A floating block: a rim of Liquid Glass around whatever is inside.
    ///
    /// The content is expected to be a `wordSlip()`. Words on glass are the
    /// documented failure of the material, and the macOS 27 slider from clear
    /// to tinted changes glass under any text that sits on it.
    ///
    /// - Parameter tint: the state the rim confirms, for the two states that
    ///   are about the person rather than the app: orange while words wait,
    ///   green for the beat after they land.
    func glassBlock(tint: StatusColorRole? = nil) -> some View {
        modifier(GlassBlock(tint: tint))
    }

    /// The opaque slip words sit on, inside a `glassBlock()`.
    func wordSlip() -> some View {
        modifier(WordSlip())
    }

    /// A block inside a window: content, never glass.
    func contentBlock(padding: CGFloat = GlassTokens.Block.padding) -> some View {
        modifier(ContentBlock(padding: padding, tint: nil))
    }

    /// A content block that carries a state: orange for something that waits
    /// for the person, green for the one success worth marking.
    func contentBlock(_ tint: StatusColorRole, padding: CGFloat = GlassTokens.Block.padding) -> some View {
        modifier(ContentBlock(padding: padding, tint: tint))
    }
}

private struct GlassBlock: ViewModifier {
    let tint: StatusColorRole?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlassTokens.Radius.surface, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(GlassTokens.Block.rim)
            .background { rim }
    }

    @ViewBuilder
    private var rim: some View {
        if reduceTransparency {
            // "Reduced Transparency makes Liquid Glass frostier." At its limit
            // that is a solid rim in the state's color.
            shape
                .fill(tint.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.background))
                .overlay { shape.stroke(.primary.opacity(0.42), lineWidth: GlassTokens.Stroke.emphasised) }
        } else if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(glass, in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.stroke(.primary.opacity(0.42), lineWidth: GlassTokens.Stroke.emphasised)
                    }
                }
        } else {
            shape
                .fill(.regularMaterial)
                .overlay { shape.fill((tint?.color ?? .clear).opacity(0.85)) }
                .overlay {
                    shape.stroke(
                        .primary.opacity(GlassTokens.Stroke.opacity(increasedContrast: contrast == .increased)),
                        lineWidth: GlassTokens.Stroke.hairline
                    )
                }
        }
    }

    /// Clear, not regular: nothing is written on the rim, so it can show the
    /// desktop it bends, and a tint on clear glass stays the state's own color
    /// where regular glass greys it out.
    @available(macOS 26.0, *)
    private var glass: Glass {
        guard let tint else { return .clear }
        return .clear.tint(tint.color)
    }
}

private struct WordSlip: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlassTokens.Block.slipRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .overlay {
                if contrast == .increased {
                    shape.stroke(.primary.opacity(0.42), lineWidth: GlassTokens.Stroke.emphasised)
                }
            }
    }
}

private struct ContentBlock: ViewModifier {
    let padding: CGFloat
    let tint: StatusColorRole?

    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlassTokens.Radius.surface, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: shape)
            .overlay {
                shape.stroke(
                    (tint?.color ?? .primary).opacity(strokeOpacity),
                    lineWidth: contrast == .increased
                        ? GlassTokens.Stroke.emphasised
                        : GlassTokens.Stroke.hairline
                )
            }
    }

    private var fill: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint.color.opacity(0.14)) }
        return AnyShapeStyle(.quaternary.opacity(0.55))
    }

    private var strokeOpacity: Double {
        if tint != nil { return contrast == .increased ? 0.9 : 0.45 }
        return GlassTokens.Stroke.opacity(increasedContrast: contrast == .increased) * 0.6
    }
}

// MARK: - State glyph

/// The shape each state wears. Shape and word carry the state; color only
/// confirms it, so every state reads in grayscale and under any color filter.
enum StateGlyph: Equatable {
    /// A hollow gray ring: the key is down and no sound has arrived. Silence
    /// is never red.
    case silent
    /// A red disc: the microphone is capturing. Red means nothing else.
    case listening
    /// A red lock: capturing with the key let go.
    case handsFree
    /// An open blue ring: the words are being written down.
    case working
    /// An orange bar: words wait for the person. Never a dot, so it cannot
    /// pass for the system's orange microphone indicator.
    case waiting
    /// The copy sign, in ink: the words are on the clipboard and still wait.
    case copied
    /// A green check: the words landed after waiting.
    case pasted
    /// An outlined tray, in ink: the words are kept in History. Kept is not
    /// waiting, so it is not orange.
    case kept
    /// A flat line, in ink: nothing was heard.
    case nothing
    /// The app has something to say that is not about a take.
    case info
    /// Something needs the person, and their work is safe.
    case attention

    var colorRole: StatusColorRole? {
        switch self {
        case .listening, .handsFree: return .recording
        case .working, .info: return .processing
        case .waiting, .attention: return .attention
        case .pasted: return .success
        case .silent, .copied, .kept, .nothing: return nil
        }
    }
}

struct StateGlyphView: View {
    let glyph: StateGlyph
    var size: CGFloat = 14

    var body: some View {
        mark
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var color: Color { glyph.colorRole?.color ?? .primary }

    @ViewBuilder
    private var mark: some View {
        switch glyph {
        case .silent:
            Circle()
                .strokeBorder(.secondary, lineWidth: size / 9)
                .padding(size / 14)
        case .listening:
            Circle().fill(color).padding(size / 14)
        case .handsFree:
            symbol("lock.fill")
        case .working:
            Circle()
                .trim(from: 0.12, to: 0.88)
                .stroke(color, style: StrokeStyle(lineWidth: size / 7, lineCap: .round))
                .rotationEffect(.degrees(90))
                .padding(size / 7)
        case .waiting:
            RoundedRectangle(cornerRadius: size / 6, style: .continuous)
                .fill(color)
                .frame(width: size, height: size * 0.5)
        case .copied:
            symbol("square.on.square")
        case .pasted:
            symbol("checkmark")
        case .kept:
            symbol("tray")
        case .nothing:
            Capsule()
                .fill(.secondary)
                .frame(width: size, height: max(1.5, size / 8))
        case .info:
            symbol("info.circle.fill")
        case .attention:
            symbol("exclamationmark.triangle.fill")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.86, weight: .bold))
            .foregroundStyle(glyph.colorRole == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
    }
}

// MARK: - Key cap

/// A key, drawn. The dictation key is the one gesture the app has, so it is
/// shown as the thing a finger rests on rather than described in a sentence.
///
/// The cap goes down when `isPressed` is true: wired to the real key, the
/// drawing answers the hand.
struct KeyCap: View {
    enum Size {
        /// Inside a line of text or a button.
        case inline
        /// A setting's current value.
        case large
        /// The one thing on the screen: onboarding.
        case hero

        var height: CGFloat {
            switch self {
            case .inline: return 22
            case .large: return 56
            case .hero: return 132
            }
        }

        var radius: CGFloat {
            switch self {
            case .inline: return 6
            case .large: return 12
            case .hero: return 22
            }
        }

        /// How far the cap travels, and how much of its side shows at rest.
        var travel: CGFloat {
            switch self {
            case .inline: return 1.5
            case .large: return 3
            case .hero: return 6
            }
        }
    }

    let title: String
    var size: Size = .inline
    var isPressed = false
    /// Drawn on the ink of a primary button rather than on a surface.
    var onInk = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .frame(minWidth: minWidth, minHeight: size.height, maxHeight: size.height)
            .background(face, in: shape)
            .overlay { shape.strokeBorder(edge, lineWidth: size == .inline ? 0.75 : 1) }
            .offset(y: isPressed ? size.travel : 0)
            .background {
                // The side of the key: what shows below the cap at rest and
                // disappears when it is down.
                shape.fill(side).offset(y: size.travel)
            }
            .padding(.bottom, size.travel)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: isPressed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
    }

    private var minWidth: CGFloat {
        switch size {
        case .inline: return size.height
        case .large: return 112
        case .hero: return 248
        }
    }

    @ViewBuilder
    private var label: some View {
        switch size {
        case .inline:
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
        case .large:
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 18)
        case .hero:
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 36)
        }
    }

    private var isDark: Bool { colorScheme == .dark }

    private var face: Color {
        if onInk { return isDark ? Color.black.opacity(0.08) : Color.white.opacity(0.16) }
        return isDark ? Color(white: 0.24) : .white
    }

    private var edge: Color {
        if onInk { return isDark ? Color.black.opacity(0.32) : Color.white.opacity(0.5) }
        return .primary.opacity(contrast == .increased ? 0.5 : (isDark ? 0.24 : 0.16))
    }

    private var side: Color {
        if onInk { return .clear }
        return isDark ? Color(white: 0.10) : Color(white: 0.72)
    }
}

// MARK: - Buttons

/// The one action a block offers: ink on the surface, so it is the darkest
/// thing in light mode and the lightest in dark.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.background)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(
                .primary.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: GlassTokens.Radius.control, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: GlassTokens.Motion.controlFeedback), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: GlassTokens.Radius.control, style: .continuous))
    }
}

/// The way out of a block: words alone, no chrome.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(
                .primary.opacity(configuration.isPressed ? 0.10 : 0),
                in: RoundedRectangle(cornerRadius: GlassTokens.Radius.control, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: GlassTokens.Radius.control, style: .continuous))
    }
}

// MARK: - Block label

/// The small word above a block's content: what the block is about.
struct BlockLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Rows in a block

/// A block of rows: the settings that are too small to be a block of their
/// own. One unit tall each, a hairline between them.
struct BlockRows<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .contentBlock(padding: 0)
    }
}

/// One row: what it is on the left, the control on the right.
struct BlockRow<Control: View>: View {
    let title: String
    var detail: String?
    var isChanged = false
    var revert: (() -> Void)?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
                .fixedSize()
            // Always in the layout, so every control in a block ends on the
            // same line whether or not its row has a default to go back to.
            RevertToDefault(isChanged: isChanged && revert != nil, revert: revert ?? {})
        }
        .padding(.horizontal, GlassTokens.Space.stack)
        .padding(.vertical, 8)
        .frame(minHeight: GlassTokens.Block.unit)
    }
}

/// The hairline between two rows of a block, inset like the rows.
struct BlockDivider: View {
    var body: some View {
        Divider().padding(.leading, GlassTokens.Space.stack)
    }
}

// MARK: - A page of blocks

/// A settings page: blocks down a scrolling column, one gap apart.
struct BlockPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GlassTokens.Space.stack) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GlassTokens.Block.padding)
        }
    }
}

/// A titled block: what it is about, the block, and a sentence under it.
struct BlockSection<Content: View, Accessory: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        _ title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.footer = footer
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassTokens.Block.gap) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    accessory()
                }
                .padding(.horizontal, GlassTokens.Space.stack)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentBlock(padding: 0)
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, GlassTokens.Space.stack)
            }
        }
    }
}

extension BlockSection where Accessory == EmptyView {
    init(
        _ title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title, footer: footer, content: content, accessory: { EmptyView() })
    }
}

/// Free-form content inside a block of rows, padded like a row.
struct BlockCell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, GlassTokens.Space.stack)
            .padding(.vertical, 12)
            .frame(minHeight: GlassTokens.Block.unit)
    }
}
