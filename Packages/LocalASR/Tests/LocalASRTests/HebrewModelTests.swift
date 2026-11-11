import LocalASR
import XCTest

/// Hebrew is a second model, offered where it can be used and used when the
/// keyboard is Hebrew.
final class HebrewModelTests: XCTestCase {
    func testTheBundledHebrewManifestIsValidAndItsOwnDownload() throws {
        let hebrew = try ModelManifest.bundledHebrew()

        XCTAssertEqual(hebrew.modelID, "parakeet-tdt-0.6b-v3-he-gguf")
        XCTAssertEqual(hebrew.repository, "vladkens/parakeet-tdt-0.6b-v3-he-gguf")
        XCTAssertEqual(hebrew.revision, "f8392f9c582f7e8276270f0c21625cd412653fcd")
        XCTAssertEqual(hebrew.quantization, "Q8_0")
        // Yakov Kolani's fine-tune of NVIDIA's Parakeet TDT 0.6B v3; attribution
        // is a licence condition.
        XCTAssertEqual(hebrew.license, "CC-BY-4.0")
        XCTAssertEqual(hebrew.files.map(\.path), ["parakeet-tdt-0.6b-v3-he-Q8_0.gguf"])
        XCTAssertEqual(hebrew.totalByteCount, 740_915_360)

        // It never shares a folder with the model the app needs.
        let main = try ModelManifest.bundled()
        let root = URL(fileURLWithPath: "/models", isDirectory: true)
        XCTAssertNotEqual(
            try ModelInstallLayout(manifest: hebrew, root: root).modelDirectory,
            try ModelInstallLayout(manifest: main, root: root).modelDirectory
        )
        if let previous = try ModelManifest.bundledPrevious() {
            XCTAssertNotEqual(hebrew.modelID, previous.modelID)
        }
    }

    func testFirstRunSetupOffersItOnlyWhereThereIsAHebrewKeyboard() {
        XCTAssertFalse(rule(enabled: ["en", "ru"]).isOfferedInSetup, "nobody else is asked about Hebrew while setting up")
        XCTAssertTrue(rule(enabled: ["en", "he"]).isOfferedInSetup)
        XCTAssertTrue(rule(enabled: ["en-US", "he-IL"]).isOfferedInSetup)
        XCTAssertTrue(rule(enabled: ["iw"]).isOfferedInSetup, "the older code for Hebrew")
        XCTAssertFalse(rule(enabled: ["hi", "hr"]).isOfferedInSetup, "Hindi and Croatian are not Hebrew")
    }

    /// The keyboard is what turns the model on, so the card has to know
    /// whether this Mac has one: without it a downloaded model is never used.
    func testItKnowsWhetherThisMacHasAHebrewKeyboard() {
        XCTAssertFalse(rule(enabled: ["en", "ru"]).hasKeyboard)
        XCTAssertFalse(rule(enabled: ["en", "ru"], model: ready).hasKeyboard, "a download does not add a keyboard")
        XCTAssertTrue(rule(enabled: ["en", "he"]).hasKeyboard)
        XCTAssertTrue(rule(current: "en", enabled: ["he-IL"]).hasKeyboard, "enabled is enough; it need not be the one in use")
    }

    func testAModelAlreadyOnDiskStaysVisibleSoItCanBeRemoved() {
        XCTAssertTrue(rule(enabled: ["en"], model: ready).isOfferedInSetup)
        XCTAssertTrue(rule(enabled: ["en"], model: .failed(.download("offline"))).isOfferedInSetup)
        XCTAssertTrue(rule(enabled: ["en"], model: .downloading(receivedBytes: 1, totalBytes: 2)).isOfferedInSetup)
    }

    func testATakeIsInHebrewWhileTheKeyboardIsHebrewAndTheModelIsReady() {
        XCTAssertTrue(rule(current: "he", enabled: ["en", "he"], model: ready).recognizes)
        XCTAssertFalse(rule(current: "en", enabled: ["en", "he"], model: ready).recognizes, "another keyboard, the main model")
        XCTAssertFalse(rule(current: "he", enabled: ["en", "he"], model: .notInstalled).recognizes, "nothing to recognize with")
        XCTAssertFalse(rule(current: "he", enabled: ["en", "he"], model: .downloading(receivedBytes: 1, totalBytes: 2)).recognizes)
        XCTAssertFalse(rule(current: nil, enabled: ["en", "he"], model: ready).recognizes, "an unknown keyboard is not Hebrew")
    }

    private let ready = ModelState.ready(directory: URL(fileURLWithPath: "/models/hebrew", isDirectory: true))

    private func rule(current: String? = "en", enabled: [String], model: ModelState = .notInstalled) -> HebrewModelRule {
        HebrewModelRule(keyboardLanguage: current, enabledKeyboardLanguages: enabled, model: model)
    }
}
