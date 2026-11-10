import AppKit
import SwiftUI

/// The parts every OpenRamble surface is built from.
///
/// Three ideas, used everywhere:
///
/// - **Glass floats, content rests.** Anything that floats — the take block,
///   the recording control, the bars over a window's content — is one piece
///   of Liquid Glass: a capsule for a line, a soft panel when it holds more.
///   Content never wears glass.
/// - **Air groups.** Inside a window there are no boxes around rows. A centred
///   column, wide margins and a hairline between rows do the grouping, and a
///   soft tile is kept for the few things that are objects: the key, the
///   microphone, something that waits for you.
/// - **Your words are set in a serif.** The app speaks in the system sans.
///   What the person said is written in New York, wherever it appears: on
///   the take block, in the Library, in the first note. Speech became text,
///   and it looks like text.

// MARK: - Type

extension Font {
    /// What the person said. Regular weight, a serif, room between the lines.
    static func words(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }

    /// A page's one headline: the same serif, larger, and never bold.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
}

// MARK: - Glass

/// The two shapes a floating block takes.
enum GlassShape {
    /// One line: a capsule, one unit tall.
    case capsule
    /// More than a line: a panel with the surface radius.
    case panel

    var shape: AnyShape {
        switch self {
        case .capsule: return AnyShape(Capsule(style: .continuous))
        case .panel: return AnyShape(RoundedRectangle(cornerRadius: GlassTokens.Radius.surface, style: .continuous))
        }
    }
}

extension View {
    /// One piece of Liquid Glass around this content.
    ///
    /// Regular glass, the variant made to carry text: it frosts and dims
    /// what is behind it as far as legibility needs, and follows the Mac's
    /// own glass setting. Reduce Transparency makes it solid; Increase
    /// Contrast adds a border; macOS 14 and 15 get the system material.
    func glassBlock(_ shape: GlassShape = .capsule) -> some View {
        modifier(GlassBlock(shape: shape))
    }

    /// A soft tile inside a window, for the few things that are objects.
    func contentBlock(padding: CGFloat = GlassTokens.Block.padding) -> some View {
        modifier(ContentBlock(padding: padding, tint: nil))
    }

    /// A tile that carries a state: orange for something that waits for the
    /// person, green for the one success worth marking.
    func contentBlock(_ tint: StatusColorRole, padding: CGFloat = GlassTokens.Block.padding) -> some View {
        modifier(ContentBlock(padding: padding, tint: tint))
    }
}

private struct GlassBlock: ViewModifier {
    let shape: GlassShape

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let outline = shape.shape
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: outline)
                .overlay { outline.stroke(.primary.opacity(0.42), lineWidth: GlassTokens.Stroke.emphasised) }
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: outline)
                .overlay {
                    if contrast == .increased {
                        outline.stroke(.primary.opacity(0.42), lineWidth: GlassTokens.Stroke.emphasised)
                    }
                }
        } else {
            content
                .background(.regularMaterial, in: outline)
                .overlay {
                    outline.stroke(
                        .primary.opacity(GlassTokens.Stroke.opacity(increasedContrast: contrast == .increased)),
                        lineWidth: GlassTokens.Stroke.hairline
                    )
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
                if contrast == .increased {
                    shape.stroke((tint?.color ?? .primary).opacity(0.6), lineWidth: GlassTokens.Stroke.emphasised)
                }
            }
    }

    /// One quiet step from the page. A tint is the state's color, thinned
    /// until it reads as a place rather than as an alarm.
    private var fill: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint.color.opacity(0.12)) }
        return AnyShapeStyle(Color.primary.opacity(0.045))
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

/// A key, drawn as the thing a finger rests on.
///
/// The dictation key is the one gesture the app has, so it is an object
/// rather than a sentence: a lit face, a side that shows its travel, a shadow
/// on the desk. The cap goes down when `isPressed` is true. Wired to the real
/// key, the drawing answers the hand.
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
            case .large: return 64
            case .hero: return 148
            }
        }

        var radius: CGFloat {
            switch self {
            case .inline: return 6
            case .large: return 15
            case .hero: return 30
            }
        }

        /// How far the cap travels, and how much of its side shows at rest.
        var travel: CGFloat {
            switch self {
            case .inline: return 1.5
            case .large: return 4
            case .hero: return 9
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
            .shadow(color: shadow, radius: isPressed ? shadowRadius * 0.35 : shadowRadius, y: isPressed ? shadowRadius * 0.2 : shadowRadius * 0.55)
            .animation(reduceMotion ? nil : .spring(duration: 0.14, bounce: 0.2), value: isPressed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
    }

    private var minWidth: CGFloat {
        switch size {
        case .inline: return size.height
        case .large: return 128
        case .hero: return 280
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
                .font(.system(size: 21, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 22)
        case .hero:
            Text(title)
                .font(.system(size: 40, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 44)
        }
    }

    private var isDark: Bool { colorScheme == .dark }

    /// Lit from above: a shade lighter at the top of the face than at the
    /// bottom, as a key under a desk lamp is.
    private var face: LinearGradient {
        let colors: [Color]
        if onInk {
            colors = isDark
                ? [Color.black.opacity(0.06), Color.black.opacity(0.10)]
                : [Color.white.opacity(0.20), Color.white.opacity(0.13)]
        } else if isDark {
            colors = [Color(white: 0.30), Color(white: 0.22)]
        } else {
            colors = [Color.white, Color(white: 0.955)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var edge: Color {
        if onInk { return isDark ? Color.black.opacity(0.30) : Color.white.opacity(0.45) }
        return .primary.opacity(contrast == .increased ? 0.5 : (isDark ? 0.20 : 0.10))
    }

    private var side: Color {
        if onInk { return .clear }
        return isDark ? Color(white: 0.09) : Color(white: 0.78)
    }

    private var shadow: Color {
        guard !onInk, size != .inline else { return .clear }
        return .black.opacity(isDark ? 0.5 : 0.16)
    }

    private var shadowRadius: CGFloat {
        switch size {
        case .inline: return 0
        case .large: return 10
        case .hero: return 26
        }
    }
}

// MARK: - Buttons

/// The one action a block offers: ink, in a capsule. Stated as colors of its
/// own rather than as label colors, because on glass a label color turns
/// translucent, and the one thing to press must not.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let dark = colorScheme == .dark
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(dark ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(
                (dark ? Color.white : Color(white: 0.09)).opacity(configuration.isPressed ? 0.82 : 1),
                in: Capsule(style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.3), value: configuration.isPressed)
            .contentShape(Capsule(style: .continuous))
    }
}

/// The way out of a block: words alone, no chrome.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.10 : 0),
                in: Capsule(style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule(style: .continuous))
    }
}

/// A control that floats on content: Liquid Glass on macOS 26, the bordered
/// style before it. A capsule either way.
extension View {
    @ViewBuilder
    func floatingButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

/// What a row in a list is, as a small disc: the same place for the eye to
/// land on every row.
struct RowDisc: View {
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(0.06), in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Labels

/// The small word above something: what it is. Quiet, never a shout.
struct BlockLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }
}

// MARK: - A page

/// A page of settings: one centred column with a wide margin, so the window
/// can grow and the reading width does not.
struct BlockPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                content()
            }
            .frame(maxWidth: GlassTokens.Block.column, alignment: .leading)
            .padding(.horizontal, GlassTokens.Block.page)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A group on a page: what it is about, its rows, and a sentence under them.
/// No box. The space around the group is the group.
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
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    accessory()
                }
                .padding(.bottom, 6)
                Divider()
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
            if let footer {
                Divider()
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
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

/// Rows with no heading: the same air, no box.
struct BlockRows<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
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
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            // Before the control, so every control on a page ends on the
            // column's own edge whether or not its row has a default to go
            // back to.
            if let revert {
                RevertToDefault(isChanged: isChanged, revert: revert)
            }
            control()
                .fixedSize()
        }
        .padding(.vertical, 8)
        .frame(minHeight: GlassTokens.Block.row)
    }
}

/// The hairline between two rows.
struct BlockDivider: View {
    var body: some View { Divider() }
}

/// Free-form content among rows, with a row's air above and below.
struct BlockCell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .frame(minHeight: GlassTokens.Block.row)
    }
}

// MARK: - The dictation key, as a control

/// The dictation key drawn as a key cap that opens the list of keys.
///
/// One control in Settings and in onboarding: the thing you press to change
/// the key looks like the key.
struct DictationKeyMenu: View {
    @Binding var hotkey: DictationHotkey
    var size: KeyCap.Size = .large
    var isPressed = false

    var body: some View {
        Menu {
            Picker(L10n.tr("Dictation key"), selection: $hotkey) {
                ForEach(DictationHotkey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            KeyCap(title: hotkey.shortTitle, size: size, isPressed: isPressed)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.tr("Dictation key"))
        .accessibilityValue(hotkey.title)
        .accessibilityHint(L10n.tr("The key you hold down while dictating"))
    }
}

/// Whether the dictation key is down, heard through this app's own windows.
///
/// A local monitor needs no permission, so the drawn key can answer the real
/// one on the first screen of onboarding, before Accessibility is granted.
/// It hears nothing while another app is in front, and stores nothing.
@MainActor
final class KeyEcho: ObservableObject {
    @Published private(set) var isDown = false
    /// The key was pressed at least once since this started listening.
    @Published private(set) var wasPressed = false

    private var monitor: Any?

    func start(for hotkey: @escaping @MainActor () -> DictationHotkey) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.rawValue
            MainActor.assumeIsolated {
                let key = hotkey()
                guard keyCode == key.keyCode else { return }
                let down = flags & key.sideMask != 0
                self?.isDown = down
                if down { self?.wasPressed = true }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isDown = false
    }
}
