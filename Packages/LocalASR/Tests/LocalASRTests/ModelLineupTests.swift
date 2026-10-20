import Foundation
import XCTest
@testable import LocalASR

/// The rule for moving from one recognition model to the next.
///
/// A person who updates the app keeps dictating with the model already on
/// their Mac. The better model is offered, downloaded only when they ask, and
/// used from the moment it verifies; only then does the old one go.
final class ModelLineupTests: XCTestCase {
    private let ready = ModelState.ready(directory: URL(fileURLWithPath: "/models/x"))

    func testANewInstallationUsesTheCurrentModel() {
        let lineup = ModelLineup(current: .notInstalled, previous: .notInstalled)
        XCTAssertEqual(lineup.recognizer, .none)
        XCTAssertFalse(lineup.offersUpgrade)
        XCTAssertFalse(lineup.removesPrevious)
        XCTAssertEqual(lineup.installs, .current)
    }

    func testAnUpdatedMacKeepsDictatingWithItsModelAndIsOfferedTheNewOne() {
        let lineup = ModelLineup(current: .notInstalled, previous: ready)
        XCTAssertEqual(lineup.recognizer, .previous)
        XCTAssertTrue(lineup.offersUpgrade)
        XCTAssertFalse(lineup.removesPrevious)
    }

    func testTheOldModelServesWhileTheNewOneDownloadsAndVerifies() {
        for state in [ModelState.downloading(receivedBytes: 1, totalBytes: 2), .verifying(checked: 0, total: 1)] {
            let lineup = ModelLineup(current: state, previous: ready)
            XCTAssertEqual(lineup.recognizer, .previous, "\(state)")
            XCTAssertFalse(lineup.offersUpgrade, "already under way: \(state)")
            XCTAssertFalse(lineup.removesPrevious, "\(state)")
        }
    }

    func testAFailedOrDamagedUpgradeFallsBackToTheOldModelAndCanBeRetried() {
        for state in [ModelState.failed(.download("offline")), .repairRequired("checksum")] {
            let lineup = ModelLineup(current: state, previous: ready)
            XCTAssertEqual(lineup.recognizer, .previous, "\(state)")
            XCTAssertTrue(lineup.offersUpgrade, "\(state)")
            XCTAssertFalse(lineup.removesPrevious, "\(state)")
        }
    }

    func testTheOldModelGoesOnlyOnceTheNewOneIsReady() {
        let lineup = ModelLineup(current: ready, previous: ready)
        XCTAssertEqual(lineup.recognizer, .current)
        XCTAssertFalse(lineup.offersUpgrade)
        XCTAssertTrue(lineup.removesPrevious)
    }

    func testAnOldModelThatIsDamagedIsNotUsedButTheNewOneIsStillOffered() {
        let lineup = ModelLineup(current: .notInstalled, previous: .repairRequired("missing file"))
        XCTAssertEqual(lineup.recognizer, .none)
        XCTAssertEqual(lineup.installs, .current)
        XCTAssertTrue(lineup.removesPrevious, "a damaged old copy is never repaired, only replaced")
    }

    func testNothingIsRemovedWhileTheNewModelIsBeingDeleted() {
        let lineup = ModelLineup(current: .deleting, previous: ready)
        XCTAssertEqual(lineup.recognizer, .previous)
        XCTAssertFalse(lineup.removesPrevious)
    }

    func testTheShippedLineupReplacesV3WithParakeetUltra() throws {
        let current = try ModelManifest.bundled()
        let previous = try XCTUnwrap(try ModelManifest.bundledPrevious())
        XCTAssertEqual(current.modelID, "parakeet-ultra-gguf")
        XCTAssertEqual(previous.modelID, "parakeet-tdt-0.6b-v3-gguf")
        XCTAssertNotEqual(current.modelID, previous.modelID, "the two must install into different folders")
    }
}
