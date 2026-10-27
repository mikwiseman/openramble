import CoreAudio
import XCTest
@testable import DictationAudio

/// The last take's microphone, kept registered but stopped for the next one.
///
/// What it must never do is hand a take a microphone that is no longer the
/// one the take would open: another device, a changed default, or one that
/// can no longer be trusted.
final class KeptMicrophoneTests: XCTestCase {
    private final class Input: ReopenableCaptureInput, @unchecked Sendable {
        let request: AudioDeviceID?
        let epoch: Int
        var reopens = true
        private(set) var reopened = 0

        init(request: AudioDeviceID?, epoch: Int) {
            self.request = request
            self.epoch = epoch
        }

        func reopen() -> Bool {
            reopened += 1
            return reopens
        }
    }

    func testTheNextTakeGetsTheKeptMicrophoneOnce() {
        let kept = KeptMicrophone<Input>()
        let input = Input(request: nil, epoch: kept.epoch)
        XCTAssertTrue(kept.keep(input))

        XCTAssertTrue(kept.reopen(for: nil) === input)
        XCTAssertEqual(input.reopened, 1)
        XCTAssertNil(kept.reopen(for: nil), "a kept microphone belongs to one take at a time")
    }

    func testATakeForAnotherDeviceLetsTheKeptOneGo() {
        let kept = KeptMicrophone<Input>()
        XCTAssertTrue(kept.keep(Input(request: 41, epoch: kept.epoch)))

        XCTAssertNil(kept.reopen(for: nil))
        XCTAssertNil(kept.reopen(for: 41), "the person chose another microphone; the old one is gone")
    }

    func testAChangeLetsTheKeptMicrophoneGo() {
        let kept = KeptMicrophone<Input>()
        XCTAssertTrue(kept.keep(Input(request: nil, epoch: kept.epoch)))
        kept.changed()

        XCTAssertNil(kept.reopen(for: nil))
    }

    /// The default input changed during the take: the microphone it ran on
    /// is no longer the one "the default" means.
    func testAMicrophoneOpenedBeforeAChangeIsNotKept() {
        let kept = KeptMicrophone<Input>()
        let input = Input(request: nil, epoch: kept.epoch)
        kept.changed()

        XCTAssertFalse(kept.keep(input))
        XCTAssertNil(kept.reopen(for: nil))
    }

    func testAMicrophoneThatCannotReopenIsNotHandedOut() {
        let kept = KeptMicrophone<Input>()
        let input = Input(request: nil, epoch: kept.epoch)
        input.reopens = false
        XCTAssertTrue(kept.keep(input))

        XCTAssertNil(kept.reopen(for: nil))
        XCTAssertNil(kept.reopen(for: nil))
    }

    func testTheLaterOfTwoStoppedMicrophonesIsKept() {
        let kept = KeptMicrophone<Input>()
        let first = Input(request: nil, epoch: kept.epoch)
        let second = Input(request: nil, epoch: kept.epoch)
        XCTAssertTrue(kept.keep(first))
        XCTAssertTrue(kept.keep(second))

        XCTAssertTrue(kept.reopen(for: nil) === second)
    }

    /// The device starts before the take's handler exists, and can change
    /// format in between; the take still hears about it.
    func testALossBeforeTheHandlerArrivesIsPassedOn() {
        let slot = HALCaptureInput.HandlerSlot()
        slot.reportLost()
        let told = expectation(description: "onLost runs")
        slot.set({ _, _ in }, onLost: { told.fulfill() })
        wait(for: [told], timeout: 1)
    }

    func testALossIsReportedOnce() {
        let slot = HALCaptureInput.HandlerSlot()
        let told = expectation(description: "onLost runs once")
        told.expectedFulfillmentCount = 1
        told.assertForOverFulfill = true
        slot.set({ _, _ in }, onLost: { told.fulfill() })
        slot.reportLost()
        slot.reportLost()
        wait(for: [told], timeout: 1)
    }
}
