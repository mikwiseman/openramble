import XCTest
@testable import DictationCore

final class EngineArbiterTests: XCTestCase {
    func testAMeetingDecodeWaitsWhileDictationRunsAndProceedsWhenItEnds() async throws {
        let arbiter = EngineArbiter(engineReady: true)
        await arbiter.setDictationActive(true)
        let proceeded = UncheckedBox(false)
        let waiter = Task {
            await arbiter.awaitMeetingTurn()
            proceeded.value = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(proceeded.value, "dictation holds the engine")
        await arbiter.setDictationActive(false)
        await waiter.value
        XCTAssertTrue(proceeded.value)
    }

    func testAColdEngineIsNobodysTurn() async throws {
        let arbiter = EngineArbiter(engineReady: false)
        let proceeded = UncheckedBox(false)
        let waiter = Task {
            await arbiter.awaitMeetingTurn()
            proceeded.value = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(proceeded.value)
        await arbiter.setEngineReady(true)
        await waiter.value
        XCTAssertTrue(proceeded.value)
    }

    /// Work on an engine of its own, such as an imported file, waits only
    /// for a dictation to end. It must not wait for the dictation engine to
    /// be loaded: that engine rests when nobody dictates, and the file would
    /// then never be transcribed.
    func testWorkOnItsOwnEngineWaitsForADictationAndNotForTheDictationEngine() async throws {
        let arbiter = EngineArbiter(engineReady: false)
        await arbiter.awaitDictationEnd()

        await arbiter.setDictationActive(true)
        let proceeded = UncheckedBox(false)
        let waiter = Task {
            await arbiter.awaitDictationEnd()
            proceeded.value = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(proceeded.value, "a dictation is running")
        await arbiter.setDictationActive(false)
        await waiter.value
        XCTAssertTrue(proceeded.value)
    }

    func testAFreeEngineReturnsAtOnce() async {
        let arbiter = EngineArbiter(engineReady: true)
        await arbiter.awaitMeetingTurn()
        let free = await arbiter.isFree
        XCTAssertTrue(free)
    }
}
