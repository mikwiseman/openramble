import AVFoundation
import ScreenCaptureKit
import XCTest

final class ScreenRecordingSetupIssueTests: XCTestCase {
    func testCameraPermissionIsSeparatedFromScreenPermission() {
        let issue = ScreenRecordingSetupIssue.from(
            ScreenRecordingError.permissionDenied("Камера")
        )

        XCTAssertEqual(issue, .cameraPermission)
        XCTAssertEqual(issue.settingsTitle, "Camera Settings")
        XCTAssertFalse(issue.canRequireRelaunch)
    }

    func testScreenCaptureTCCFailureOffersScreenRecovery() {
        let issue = ScreenRecordingSetupIssue.from(
            NSError(domain: SCStreamErrorDomain, code: -3801)
        )

        XCTAssertEqual(issue, .screenPermission)
        XCTAssertEqual(issue.settingsTitle, "Screen Recording Settings")
        XCTAssertTrue(issue.canRequireRelaunch)
    }

    func testCameraAuthorizationNSErrorDoesNotBecomeScreenPermission() {
        let issue = ScreenRecordingSetupIssue.from(
            NSError(
                domain: AVFoundationErrorDomain,
                code: AVError.Code.applicationIsNotAuthorizedToUseDevice.rawValue
            )
        )

        XCTAssertEqual(issue, .cameraPermission)
        XCTAssertFalse(issue.canRequireRelaunch)
    }
}
