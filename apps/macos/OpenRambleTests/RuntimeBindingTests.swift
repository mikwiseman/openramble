import LocalASR
import XCTest

/// The app runs exactly one copy of the inference runtime: the CTranscribe
/// framework LocalASR pins.
///
/// This bundle links the way the app does, so a second copy linked in
/// statically, as the shared core did until 0.34, answers here too. Then the
/// code that runs is neither the audited binary nor the measured one, and its
/// version is whatever the Rust crates happen to pin.
final class RuntimeBindingTests: XCTestCase {
    func testTheRuntimeComesFromThePinnedFramework() throws {
        let image = try XCTUnwrap(TranscribeCppAdapter.runtimeImagePath)
        XCTAssertTrue(image.contains("/CTranscribe.framework/"), image)
    }
}
