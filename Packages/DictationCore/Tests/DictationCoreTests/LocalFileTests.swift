import XCTest
@testable import DictationCore

/// File reading exists as a separate type for the sake of one promise: application
/// does not go online. `Data(contentsOf:)` accepts any address and silently via http
/// goes outside, which is why the network surface check would not be able to distinguish
/// read settings from an undeclared send. Refusal for non-file address -
/// not a trifle, but what this check rests on.
final class LocalFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "localfile-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRefusesAnyAddressThatIsNotAFile() throws {
        // Exactly the case for which the type was written: an address leading outside,
        // rejected before any reading.
        for address in [
            "https://huggingface.co/model.json",
            "http://localhost:8080/settings",
            "ftp://example.org/file",
        ] {
            let url = try XCTUnwrap(URL(string: address))

            XCTAssertThrowsError(try LocalFile.read(url), "\u{0410}\u{0434}\u{0440}\u{0435}\u{0441}: \(address)") { error in
                guard case let .notAFileURL(scheme) = error as? LocalFile.Failure else {
                    return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} \u{043E}\u{0442}\u{043A}\u{0430}\u{0437} \u{043F}\u{043E} \u{0441}\u{0445}\u{0435}\u{043C}\u{0435} \u{0430}\u{0434}\u{0440}\u{0435}\u{0441}\u{0430}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
                }
                XCTAssertEqual(scheme, url.scheme)
            }
        }
    }

    func testReadsLocalFileByteForByte() throws {
        let url = directory.appending(path: "\u{043C}\u{0430}\u{043D}\u{0438}\u{0444}\u{0435}\u{0441}\u{0442}.json", directoryHint: .notDirectory)
        let payload = Data("{\"\u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C}\": \"parakeet\"}".utf8)
        try payload.write(to: url)

        XCTAssertEqual(try LocalFile.read(url), payload)
    }

    func testMissingFileIsAnError() throws {
        // A missing manifest is a broken application build, and be silent
        // we can't talk about this: without a manifest, the model installation has no root of trust.
        let url = directory.appending(path: "\u{043D}\u{0435}\u{0442}-\u{0442}\u{0430}\u{043A}\u{043E}\u{0433}\u{043E}.json", directoryHint: .notDirectory)

        XCTAssertThrowsError(try LocalFile.read(url)) { error in
            guard case .unreadable = error as? LocalFile.Failure else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0447}\u{0442}\u{0435}\u{043D}\u{0438}\u{044F}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    func testEmptyFileReadsAsEmptyData() throws {
        // An empty file is not a read error. The one who will deal with the emptiness is the one
        // who requested the content.
        let url = directory.appending(path: "\u{043F}\u{0443}\u{0441}\u{0442}\u{043E}.json", directoryHint: .notDirectory)
        try Data().write(to: url)

        XCTAssertEqual(try LocalFile.read(url), Data())
    }
}
