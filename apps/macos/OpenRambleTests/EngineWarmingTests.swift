import XCTest

/// A ready engine is refreshed on every recording start. Core ML exposes no
/// portable residency timer across Apple Silicon generations.
final class EngineWarmingTests: XCTestCase {
    func testReadyEnginePingsOnEveryRecordingStart() {
        XCTAssertTrue(EngineWarming.shouldPingOnRecordingStart(engineReady: true))
        XCTAssertTrue(EngineWarming.shouldPingOnRecordingStart(engineReady: true))
    }

    func testNotReadyEngineUsesTheFullReloadPathInsteadOfAPing() {
        XCTAssertFalse(EngineWarming.shouldPingOnRecordingStart(engineReady: false))
    }
}
