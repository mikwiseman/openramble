import LocalASR
import XCTest

/// Combining the states of two models into one that a person can see.
///
/// For a person, recognition and suggestion of terms is one “model”: one
/// button, one progress, one destiny. The rules of association are pure politics,
/// and each of them is recorded here.
final class ModelPairStateTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/engine")

    private func combined(_ main: ModelState, _ vocabulary: ModelState) -> ModelState {
        ModelPairState.combine(
            main: main,
            vocabulary: vocabulary,
            mainTotalBytes: 480,
            vocabularyTotalBytes: 100,
            mainFileCount: 21,
            vocabularyFileCount: 16
        )
    }

    func testScenario001() {
        let state = combined(.ready(directory: directory), .ready(directory: URL(fileURLWithPath: "/tmp/ctc")))

        XCTAssertEqual(state, .ready(directory: directory))
    }

    func testScenario002() {
        // Adding after updating the application: the main one is already there, the hint
        // not yet. For a person, this is “the model is not ready, download the rest.”
        let state = combined(.ready(directory: directory), .notInstalled)

        XCTAssertEqual(state, .notInstalled)
    }

    func testScenario003() {
        let state = combined(.downloading(receivedBytes: 50, totalBytes: 480), .notInstalled)

        XCTAssertEqual(state, .downloading(receivedBytes: 50, totalBytes: 580))
    }

    func testScenario004() {
        // The main one has already been downloaded: progress has no right to jump back to zero.
        let state = combined(
            .ready(directory: directory),
            .downloading(receivedBytes: 30, totalBytes: 100)
        )

        XCTAssertEqual(state, .downloading(receivedBytes: 510, totalBytes: 580))
    }

    func testScenario005() {
        let state = combined(.verifying(checked: 3, total: 21), .notInstalled)

        XCTAssertEqual(state, .verifying(checked: 3, total: 37))
    }

    func testScenario006() {
        let state = combined(.ready(directory: directory), .verifying(checked: 3, total: 16))

        XCTAssertEqual(state, .verifying(checked: 24, total: 37))
    }

    func testScenario007() {
        let failure = ModelStoreError.download("broken")
        XCTAssertEqual(combined(.failed(failure), .notInstalled), .failed(failure))
        XCTAssertEqual(combined(.ready(directory: directory), .failed(failure)), .failed(failure))
    }

    func testScenario008() {
        let state = combined(.ready(directory: directory), .repairRequired("checksums didn't match"))

        guard case let .repairRequired(detail) = state else {
            return XCTFail("Expected repairRequired, received: \(state)")
        }
        XCTAssertTrue(detail.contains("vocabulary helper"), "The reason must name the culprit: \(detail)")
        XCTAssertTrue(detail.contains("checksums didn't match"))
    }

    func testScenario009() {
        XCTAssertEqual(combined(.deleting, .ready(directory: directory)), .deleting)
        XCTAssertEqual(combined(.ready(directory: directory), .deleting), .deleting)
    }

    func testScenario010() {
        // The button must name the real volume: full for a clean installation,
        // only the remainder is for addition.
        XCTAssertEqual(
            ModelPairState.remainingBytes(
                main: .notInstalled, vocabulary: .notInstalled,
                mainTotalBytes: 480, vocabularyTotalBytes: 100,
                engineRejectedModels: false
            ),
            580
        )
        XCTAssertEqual(
            ModelPairState.remainingBytes(
                main: .ready(directory: directory), vocabulary: .notInstalled,
                mainTotalBytes: 480, vocabularyTotalBytes: 100,
                engineRejectedModels: false
            ),
            100
        )
        XCTAssertEqual(
            ModelPairState.remainingBytes(
                main: .ready(directory: directory), vocabulary: .repairRequired("x"),
                mainTotalBytes: 480, vocabularyTotalBytes: 100,
                engineRejectedModels: false
            ),
            100
        )
        // Core ML refused an intact copy: nothing is missing from disk, and the
        // repair still downloads both models. Asking what is missing gives 0,
        // which is what the "Redownload Model — 0 MB" button was saying.
        XCTAssertEqual(
            ModelPairState.remainingBytes(
                main: .ready(directory: directory), vocabulary: .ready(directory: directory),
                mainTotalBytes: 480, vocabularyTotalBytes: 100,
                engineRejectedModels: true
            ),
            580
        )
    }
}
