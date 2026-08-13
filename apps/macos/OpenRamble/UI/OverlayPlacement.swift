import Foundation

/// Where the non-activating dictation panel sits on the screen being used.
public enum DictationOverlayPlacement: String, CaseIterable, Identifiable, Sendable {
    case top
    case bottom

    public var id: Self { self }

    var title: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
}

/// Pure geometry for the panel. `visibleFrame` already excludes the menu bar
/// and the visible Dock, so both choices keep the feedback out of system UI.
enum OverlayPlacementPolicy {
    static let edgeInset: CGFloat = 24

    static func origin(
        placement: DictationOverlayPlacement,
        visibleFrame: CGRect,
        panelSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: placement == .top
                ? visibleFrame.maxY - panelSize.height - edgeInset
                : visibleFrame.minY + edgeInset
        )
    }
}

@MainActor
protocol OverlayPlacementConfiguring: AnyObject {
    var placement: DictationOverlayPlacement { get set }
}
