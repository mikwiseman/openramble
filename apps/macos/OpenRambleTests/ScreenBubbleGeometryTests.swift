import CoreGraphics
import DictationCore
import XCTest

final class ScreenBubbleGeometryTests: XCTestCase {
    func testScaleIsBounded() {
        XCTAssertEqual(ScreenBubbleGeometry.clampedScale(-1), ScreenBubbleGeometry.minimumScale)
        XCTAssertEqual(ScreenBubbleGeometry.clampedScale(2), ScreenBubbleGeometry.maximumScale)
        XCTAssertEqual(ScreenBubbleGeometry.clampedScale(.nan), 0.20)
    }

    func testPositionIsClampedToKeepCircleOnScreen() {
        let size = CGSize(width: 1_920, height: 1_080)
        let position = ScreenBubbleGeometry.clampedPosition(
            NormalizedPoint(x: -1, y: 3), scale: 0.20, in: size
        )
        let rect = ScreenBubbleGeometry.rect(in: size, scale: 0.20, position: position)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, size.width)
        XCTAssertLessThanOrEqual(rect.maxY, size.height)
    }

    func testPositionRoundTripsBetweenDisplayAndVideoCoordinates() {
        let display = CGRect(x: 1_440, y: 200, width: 1_920, height: 1_080)
        let position = NormalizedPoint(x: 0.22, y: 0.76)
        let rect = ScreenBubbleGeometry.rect(in: display.size, scale: 0.20, position: position)
            .offsetBy(dx: display.minX, dy: display.minY)
        let result = ScreenBubbleGeometry.position(for: rect, in: display)
        XCTAssertEqual(result.x, position.x, accuracy: 0.001)
        XCTAssertEqual(result.y, position.y, accuracy: 0.001)
    }
}
