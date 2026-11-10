import AppKit
import DictationCore
import SwiftUI

/// The menu bar presence: the brand mark, with a small badge over its corner
/// while the microphone is live or something waits for the person.
///
/// Red is a dot, and the only dot. Orange is a bar: macOS draws its own round
/// orange microphone indicator a few points away, and a round orange badge of
/// ours would pass for it.
///
/// The label owns no clock and no animation: state arrives from outside and
/// each state maps to one static image, so the menu bar costs nothing at rest.
struct MenuBarLabel: View {
    let state: DictationState
    let isDictationReady: Bool
    let wordsAreWaiting: Bool
    let setupNeedsAttention: Bool
    var isRecordingMeeting = false
    var recordingIsDegraded = false
    var microphoneMissing = false

    var body: some View {
        let badge = MenuBarStatus.badge(
            activity: MenuBarStatus.activity(state: state, isRecordingMeeting: isRecordingMeeting),
            needsAttention: wordsAreWaiting || setupNeedsAttention,
            recordingIsDegraded: recordingIsDegraded || microphoneMissing
        )

        label(badge: badge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                MenuBarStatus.accessibilityLabel(
                    state: state,
                    isDictationReady: isDictationReady,
                    wordsAreWaiting: wordsAreWaiting,
                    isRecordingMeeting: isRecordingMeeting,
                    recordingIsDegraded: recordingIsDegraded,
                    microphoneMissing: microphoneMissing
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
        case .attention: return attention
        }
    }

    static let recording = composite(
        badge: StatusColorRole.recording.nsColor,
        size: NSSize(width: 7, height: 7)
    )
    static let attention = composite(
        badge: StatusColorRole.attention.nsColor,
        size: NSSize(width: 10, height: 5)
    )

    private static let canvas = NSSize(width: 22, height: 22)

    /// - Parameter size: a square is drawn as a dot, anything else as a bar
    ///   with rounded ends that stops short of a capsule.
    private static func composite(badge dot: NSColor, size: NSSize) -> NSImage {
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
                x: rect.maxX - size.width,
                y: rect.maxY - size.height - (size.width == size.height ? 0 : 1),
                width: size.width,
                height: size.height
            )
            let radius = size.width == size.height ? size.height / 2 : 1.5
            func path(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            }

            // A thin transparent ring punched out of the mark separates the
            // dot like a system badge — readable on any wallpaper without
            // adding a stroke of its own.
            if let context = NSGraphicsContext.current {
                let previous = context.compositingOperation
                context.compositingOperation = .destinationOut
                path(dotRect.insetBy(dx: -1.5, dy: -1.5), radius + 1.5).fill()
                context.compositingOperation = previous
            }

            dot.setFill()
            path(dotRect, radius).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = nil
        return image
    }
}
