import Foundation
import XCTest

/// The Handy-style "Unload Model" row: seven options, five-minute default.
final class IdleUnloadPolicyTests: XCTestCase {
    func testDelaysMatchTheirLabels() {
        XCTAssertNil(IdleUnloadPolicy.never.idleDelay)
        XCTAssertEqual(IdleUnloadPolicy.immediately.idleDelay, .zero)
        XCTAssertEqual(IdleUnloadPolicy.afterTwoMinutes.idleDelay, .seconds(120))
        XCTAssertEqual(IdleUnloadPolicy.afterFiveMinutes.idleDelay, .seconds(300))
        XCTAssertEqual(IdleUnloadPolicy.afterTenMinutes.idleDelay, .seconds(600))
        XCTAssertEqual(IdleUnloadPolicy.afterFifteenMinutes.idleDelay, .seconds(900))
        XCTAssertEqual(IdleUnloadPolicy.afterOneHour.idleDelay, .seconds(3_600))
        XCTAssertEqual(IdleUnloadPolicy.allCases.count, 7)
    }

    func testDefaultMatchesHandy() {
        XCTAssertEqual(IdleUnloadPolicy.default, .afterFiveMinutes)
    }

    func testStoredFallsBackToDefaultOnGarbageAndAbsence() throws {
        let suite = "is.waiwai.dictation.tests.idle-unload-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(IdleUnloadPolicy.stored(in: defaults), .default)
        defaults.set("after-nine-lives", forKey: IdleUnloadPolicy.defaultsKey)
        XCTAssertEqual(IdleUnloadPolicy.stored(in: defaults), .default)
        defaults.set(IdleUnloadPolicy.afterOneHour.rawValue, forKey: IdleUnloadPolicy.defaultsKey)
        XCTAssertEqual(IdleUnloadPolicy.stored(in: defaults), .afterOneHour)
    }
}
