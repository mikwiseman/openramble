import CoreGraphics
import DictationCore
import Foundation

/// Positions are circle centres measured from the top-left of the display.
/// The same geometry is used in AppKit points and in encoded video pixels.
enum ScreenBubbleGeometry {
    static let minimumScale = 0.12
    static let maximumScale = 0.34

    static func clampedScale(_ value: Double) -> Double {
        guard value.isFinite else { return 0.20 }
        return min(max(value, minimumScale), maximumScale)
    }

    /// The scale a bubble of this diameter has on a display of this size —
    /// how a size the person set on screen becomes the size that records.
    static func scale(forDiameter diameter: CGFloat, in size: CGSize) -> Double {
        let side = min(size.width, size.height)
        guard side > 0 else { return clampedScale(.nan) }
        return clampedScale(diameter / side)
    }

    /// The diameters the recorder draws on a display of this size.
    static func diameterRange(in size: CGSize) -> ClosedRange<CGFloat> {
        let side = min(size.width, size.height)
        return side * minimumScale...side * maximumScale
    }

    /// The corner drag: grows towards the pointer with the top left held,
    /// following whichever direction moved further. AppKit's y grows upward,
    /// so `drag.height` is the pointer's downward travel.
    static func resized(_ frame: CGRect, drag: CGSize) -> CGRect {
        let growth = abs(drag.width) >= abs(drag.height) ? drag.width : drag.height
        let side = max(1, frame.width + growth)
        return CGRect(x: frame.minX, y: frame.maxY - side, width: side, height: side)
    }

    static func clampedPosition(_ value: NormalizedPoint, scale: Double, in size: CGSize) -> NormalizedPoint {
        guard size.width > 0, size.height > 0 else { return NormalizedPoint(x: 0.5, y: 0.5) }
        let radius = min(size.width, size.height) * clampedScale(scale) / 2
        let x = value.x.isFinite ? value.x : 0.5
        let y = value.y.isFinite ? value.y : 0.5
        return NormalizedPoint(
            x: min(max(x, radius / size.width), 1 - radius / size.width),
            y: min(max(y, radius / size.height), 1 - radius / size.height)
        )
    }

    /// AppKit and Core Image both use bottom-left coordinates.
    static func rect(in size: CGSize, scale: Double, position: NormalizedPoint) -> CGRect {
        let position = clampedPosition(position, scale: scale, in: size)
        let diameter = min(size.width, size.height) * clampedScale(scale)
        let maxX = max(0, size.width - diameter)
        let maxY = max(0, size.height - diameter)
        return CGRect(
            x: min(max(position.x * size.width - diameter / 2, 0), maxX),
            y: min(max((1 - position.y) * size.height - diameter / 2, 0), maxY),
            width: diameter,
            height: diameter
        )
    }

    static func position(for rect: CGRect, in display: CGRect) -> NormalizedPoint {
        guard display.width > 0, display.height > 0 else { return NormalizedPoint(x: 0.5, y: 0.5) }
        return NormalizedPoint(
            x: (rect.midX - display.minX) / display.width,
            y: 1 - (rect.midY - display.minY) / display.height
        )
    }

    /// H.264 needs even dimensions. Keep the display's aspect ratio and cap
    /// the long side at 4K so large Retina desktops do not overwhelm capture.
    static func videoSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let width = max(width, 2)
        let height = max(height, 2)
        let factor = min(1, 3840 / Double(max(width, height)),
                         sqrt(8_294_400 / (Double(width) * Double(height))))
        return (max(Int(Double(width) * factor) & ~1, 2), max(Int(Double(height) * factor) & ~1, 2))
    }
}
