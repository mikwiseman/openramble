import Foundation
import XCTest
@testable import DictationCore

final class LocalizationResourceTests: XCTestCase {
    func testCatalogsHaveMatchingKeysAndFormatArguments() throws {
        func catalog(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try catalog("en"), russian = try catalog("ru")
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        for (key, value) in english {
            XCTAssertFalse(try XCTUnwrap(russian[key]).isEmpty, key)
            XCTAssertEqual(value.components(separatedBy: "%@").count,
                           russian[key]?.components(separatedBy: "%@").count, key)
        }
    }
}
