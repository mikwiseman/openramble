import XCTest

@MainActor
final class OverlayPlacementTests: XCTestCase {
    func testTopCentersPanelBelowVisibleFrameEdge() {
        let origin = OverlayPlacementPolicy.origin(
            placement: .top,
            visibleFrame: CGRect(x: 100, y: 40, width: 1200, height: 760),
            panelSize: CGSize(width: 244, height: 52)
        )

        XCTAssertEqual(origin.x, 578)
        XCTAssertEqual(origin.y, 724)
    }

    func testBottomCentersPanelAboveVisibleFrameEdge() {
        let origin = OverlayPlacementPolicy.origin(
            placement: .bottom,
            visibleFrame: CGRect(x: 100, y: 40, width: 1200, height: 760),
            panelSize: CGSize(width: 244, height: 52)
        )

        XCTAssertEqual(origin.x, 578)
        XCTAssertEqual(origin.y, 64)
    }

    func testPlacementDefaultsToTopAndPersists() throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        let state = harness.makeState()
        XCTAssertEqual(state.overlayPlacement, .top)

        state.overlayPlacement = .bottom

        XCTAssertEqual(harness.defaults.string(forKey: "overlayPlacement"), "bottom")
    }
}
