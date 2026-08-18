import Foundation
import XCTest

/// The Handy-style "Unload Model" row: seven options, resident by default.
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

    /// The reload after an unload is invisible only while the OS still has the
    /// model specialized; after a cache purge it costs 13.5-16 s, and the
    /// countdown decides when to risk that on someone's behalf. Nobody opts
    /// into that by default.
    func testDefaultKeepsTheEngineResident() {
        XCTAssertEqual(IdleUnloadPolicy.default, .never)
        XCTAssertNil(IdleUnloadPolicy.default.idleDelay)
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
