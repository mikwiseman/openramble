import AppKit
import DictationCore
import SwiftUI

/// The menu bar presence: the brand mark, with a small colored dot over its
/// corner while the app records, works on speech, or needs the person.
///
/// The label owns no clock and no animation: state arrives from outside and
/// each state maps to one static image, so the menu bar costs nothing at rest.
struct MenuBarLabel: View {
    let state: DictationState
    let isDictationReady: Bool
    let hasRecoveredWork: Bool
    let setupNeedsAttention: Bool
    var isRecordingMeeting = false

    var body: some View {
        let badge = MenuBarStatus.badge(
            activity: MenuBarStatus.activity(state: state, isRecordingMeeting: isRecordingMeeting),
            needsAttention: hasRecoveredWork || setupNeedsAttention
        )

        label(badge: badge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                MenuBarStatus.accessibilityLabel(
                    state: state,
                    isDictationReady: isDictationReady,
                    hasRecoveredWork: hasRecoveredWork,
                    isRecordingMeeting: isRecordingMeeting
                )
            )
    }

    /// MenuBarExtra rasterizes its label and template-tints every SwiftUI view
    /// inside, which strips color — a red shape comes out white. The one thing
    /// it leaves untouched is a single non-template NSImage, so each badge
    /// state is pre-flattened into one image: brand mark plus colored dot.
    /// At rest the plain template asset keeps the exact system treatment
    /// (vibrancy, inversion while the menu is open).
    @ViewBuilder
    private func label(badge: MenuBarBadge) -> some View {
        if let art = MenuBarLabelArt.image(badge: badge) {
            Image(nsImage: art)
        } else {
            Image(MenuBarStatus.brandIconName)
        }
    }
}

/// Pre-rendered label images for the badge states.
///
/// Each image is built once and cached; AppKit re-runs the drawing handler
/// per appearance, so `labelColor` and the system colors resolve against the
/// menu bar's look at draw time — light and dark both stay correct.
@MainActor
enum MenuBarLabelArt {
    static func image(badge: MenuBarBadge) -> NSImage? {
        switch badge {
        case .hidden: return nil
        case .recording: return recording
        case .working: return working
        case .attention: return attention
        }
    }

    static let recording = composite(dot: StatusColorRole.recording.nsColor)
    static let working = composite(dot: StatusColorRole.processing.nsColor)
    static let attention = composite(dot: StatusColorRole.attention.nsColor)

    private static let canvas = NSSize(width: 22, height: 22)
    private static let dotDiameter: CGFloat = 7

    private static func composite(dot: NSColor) -> NSImage {
        let brand = NSImage(named: MenuBarStatus.brandIconName)
        let image = NSImage(size: canvas, flipped: false) { rect in
            // The brand mark, tinted to the label color of whatever appearance
            // is current when AppKit draws — the manual equivalent of template
            // rendering, needed because the composite itself must stay
            // non-template to keep the dot's color.
            if let brand {
                brand.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
            }

            let dotRect = NSRect(
                x: rect.maxX - dotDiameter,
                y: rect.maxY - dotDiameter,
                width: dotDiameter,
                height: dotDiameter
            )

            // A thin transparent ring punched out of the mark separates the
            // dot like a system badge — readable on any wallpaper without
            // adding a stroke of its own.
            if let context = NSGraphicsContext.current {
                let previous = context.compositingOperation
                context.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
                context.compositingOperation = previous
            }

            dot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = nil
        return image
    }
}
