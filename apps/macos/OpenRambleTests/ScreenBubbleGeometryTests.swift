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

    /// What is on screen is what records. The bubble used to record at the
    /// size its slider last set, whatever the person did to the bubble itself:
    /// resizing it on screen moved its centre in the recording and left its
    /// size behind. A frame read back from the screen now names the very
    /// circle the compositor draws, in display points and in video pixels.
    func testTheOnScreenBubbleIsTheRecordedBubble() {
        let display = CGRect(x: 1_440, y: 200, width: 1_920, height: 1_080)
        let onScreen = CGRect(x: 1_640, y: 700, width: 280, height: 280)

        let scale = ScreenBubbleGeometry.scale(forDiameter: onScreen.width, in: display.size)
        let position = ScreenBubbleGeometry.position(for: onScreen, in: display)
        let drawn = ScreenBubbleGeometry.rect(in: display.size, scale: scale, position: position)
            .offsetBy(dx: display.minX, dy: display.minY)

        XCTAssertEqual(drawn.minX, onScreen.minX, accuracy: 0.5)
        XCTAssertEqual(drawn.minY, onScreen.minY, accuracy: 0.5)
        XCTAssertEqual(drawn.width, onScreen.width, accuracy: 0.5)

        // The same circle in a 4K-capped video of that display.
        let video = ScreenBubbleGeometry.videoSize(width: 3_840, height: 2_160)
        let videoSize = CGSize(width: video.width, height: video.height)
        let recorded = ScreenBubbleGeometry.rect(in: videoSize, scale: scale, position: position)
        XCTAssertEqual(recorded.width / videoSize.height, onScreen.width / display.height, accuracy: 0.001)
        XCTAssertEqual(recorded.midX / videoSize.width, (onScreen.midX - display.minX) / display.width, accuracy: 0.001)
    }

    /// A bubble dragged beyond what the recorder draws comes back to its
    /// limit, so the screen can never show a size that will not record.
    func testTheOnScreenSizeIsBoundedLikeTheRecording() {
        let size = CGSize(width: 1_920, height: 1_080)
        XCTAssertEqual(ScreenBubbleGeometry.scale(forDiameter: 2_000, in: size), ScreenBubbleGeometry.maximumScale)
        XCTAssertEqual(ScreenBubbleGeometry.scale(forDiameter: 10, in: size), ScreenBubbleGeometry.minimumScale)
        let range = ScreenBubbleGeometry.diameterRange(in: size)
        XCTAssertEqual(range.lowerBound, 1_080 * ScreenBubbleGeometry.minimumScale, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 1_080 * ScreenBubbleGeometry.maximumScale, accuracy: 0.001)
    }

    /// Dragging the corner grows the circle towards the pointer, with its top
    /// left held still — it used to grow away from the pointer.
    func testTheCornerDragGrowsTowardsThePointer() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 200)

        let wider = ScreenBubbleGeometry.resized(start, drag: CGSize(width: 40, height: 10))
        XCTAssertEqual(wider.width, 240)
        XCTAssertEqual(wider.height, 240)
        XCTAssertEqual(wider.minX, start.minX, "left edge holds")
        XCTAssertEqual(wider.maxY, start.maxY, "top edge holds")

        let smaller = ScreenBubbleGeometry.resized(start, drag: CGSize(width: -10, height: -60))
        XCTAssertEqual(smaller.width, 140, "the larger movement wins")
        XCTAssertEqual(smaller.maxY, start.maxY)
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
