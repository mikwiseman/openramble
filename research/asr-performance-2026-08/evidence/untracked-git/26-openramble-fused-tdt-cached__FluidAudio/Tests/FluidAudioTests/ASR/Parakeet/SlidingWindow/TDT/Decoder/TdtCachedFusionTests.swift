import XCTest

@testable import FluidAudio

final class TdtCachedFusionTests: XCTestCase {
    private enum ExpectedFailure: Error {
        case invalidCandidate
    }

    func testSOSPairsDecoderWithFirstJointWhenFrameExists() {
        XCTAssertEqual(
            TdtCachedFusionScheduler.afterDecoderToken(
                fusedAvailable: true,
                nextEncoderFrame: 0
            ),
            .fusedDecoderAndJoint(frame: 0)
        )
    }

    func testBlankStreakRetainsJointOnlyCachedDecoderSemantics() {
        let trace = [0, 2, 5, 9].map(TdtCachedFusionScheduler.forBlankCacheHit(frame:))
        XCTAssertEqual(
            trace,
            [
                .jointOnly(frame: 0),
                .jointOnly(frame: 2),
                .jointOnly(frame: 5),
                .jointOnly(frame: 9),
            ]
        )
    }

    func testNonBlankDurationLeapPrefetchesThePostLeapFrame() {
        let emissionFrame = 3
        let mappedDuration = 4
        let nextFrame = emissionFrame + mappedDuration
        XCTAssertEqual(
            TdtCachedFusionScheduler.afterDecoderToken(
                fusedAvailable: true,
                nextEncoderFrame: nextFrame
            ),
            .fusedDecoderAndJoint(frame: 7)
        )
    }

    func testForcedAdvanceIsAppliedBeforeFusedFrameSelection() {
        let emissionFrame = 11
        let mappedDuration = 0
        let forceAdvance = 1
        let postFixFrame = emissionFrame + mappedDuration + forceAdvance
        XCTAssertEqual(
            TdtCachedFusionScheduler.afterDecoderToken(
                fusedAvailable: true,
                nextEncoderFrame: postFixFrame
            ),
            .fusedDecoderAndJoint(frame: 12)
        )
    }

    func testMaxTokenLimitStopsBeforeDecoderStateCommit() {
        XCTAssertEqual(
            TdtCachedFusionScheduler.afterDecoderToken(
                fusedAvailable: true,
                nextEncoderFrame: 12,
                tokenLimitExceeded: true
            ),
            .stop
        )
    }

    func testCancellationBetweenPredictionAndCommitLeavesVisibleStateUntouched() {
        var visibleState = 41
        let candidate = TdtCachedFusionAtomicCandidate(value: 42)

        XCTAssertThrowsError(
            try candidate.commit(
                into: &visibleState,
                beforeCommit: { throw CancellationError() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(visibleState, 41)
    }

    func testValidationErrorBetweenPredictionAndCommitLeavesVisibleStateUntouched() {
        var visibleState = "shipping-A"
        let candidate = TdtCachedFusionAtomicCandidate(value: "fused-B")

        XCTAssertThrowsError(
            try candidate.commit(
                into: &visibleState,
                beforeCommit: { throw ExpectedFailure.invalidCandidate }
            )
        )
        XCTAssertEqual(visibleState, "shipping-A")
    }

    func testLongFormChunkHandoffUsesDecoderOnlyWhenNextFrameIsUnavailable() {
        XCTAssertEqual(
            TdtCachedFusionScheduler.afterDecoderToken(
                fusedAvailable: true,
                nextEncoderFrame: nil
            ),
            .decoderOnly(.noFollowingEncoderFrame)
        )
    }

    func testLastChunkMaxSymbolFlushStaysOnShippingDecoderOnlyPath() {
        XCTAssertEqual(
            TdtCachedFusionScheduler.afterDecoderToken(
                fusedAvailable: true,
                nextEncoderFrame: 99,
                isLastChunkFlush: true
            ),
            .decoderOnly(.lastChunkFlush)
        )
    }

    func testOverlapSuppressedTokenStillSchedulesStateAdvance() {
        let emittedToTranscript = false
        XCTAssertFalse(emittedToTranscript)
        XCTAssertEqual(
            TdtCachedFusionScheduler.afterDecoderToken(
                fusedAvailable: true,
                nextEncoderFrame: 18
            ),
            .fusedDecoderAndJoint(frame: 18)
        )
    }

    func testMissingArtifactFallsBackToSeparateDecoder() {
        XCTAssertEqual(
            TdtCachedFusionScheduler.afterDecoderToken(
                fusedAvailable: false,
                nextEncoderFrame: 3
            ),
            .decoderOnly(.noFusedArtifact)
        )
    }

    func testAliasGuardAcceptsDisjointAndAdjacentRegions() {
        let outputs = [
            region("h_out", 100, 200),
            region("c_out", 200, 300),
            region("decoder", 400, 500),
        ]
        let inputs = [
            region("h_in", 1_000, 1_100),
            region("c_in", 1_100, 1_200),
            region("encoder_step", 1_300, 1_400),
        ]

        XCTAssertNil(
            TdtCachedFusionAliasGuard.firstConflict(
                mutableOutputs: outputs,
                protectedInputs: inputs
            )
        )
    }

    func testAliasGuardRejectsEveryMutableOutputInputCrossAlias() {
        let outputNames = ["h_out", "c_out", "decoder"]
        let inputNames = ["targets", "target_length", "h_in", "c_in", "encoder_step"]

        for (outputIndex, outputName) in outputNames.enumerated() {
            for (inputIndex, inputName) in inputNames.enumerated() {
                let outputStart = UInt(1_000 + outputIndex * 1_000)
                let outputs = outputNames.enumerated().map { index, name in
                    let start = UInt(1_000 + index * 1_000)
                    return region(name, start, start + 100)
                }
                let inputs = inputNames.enumerated().map { index, name in
                    let start =
                        index == inputIndex
                        ? outputStart + 50
                        : UInt(10_000 + index * 1_000)
                    return region(name, start, start + 100)
                }

                XCTAssertEqual(
                    TdtCachedFusionAliasGuard.firstConflict(
                        mutableOutputs: outputs,
                        protectedInputs: inputs
                    ),
                    TdtCachedFusionAliasConflict(
                        mutableOutput: outputName,
                        otherRegion: inputName
                    ),
                    "missed \(outputName) vs \(inputName)"
                )
            }
        }
    }

    func testAliasGuardRejectsEveryMutableOutputPairIncludingPartialOverlap() {
        let pairs = [("h_out", "c_out"), ("h_out", "decoder"), ("c_out", "decoder")]

        for (firstName, secondName) in pairs {
            let names = ["h_out", "c_out", "decoder"]
            let outputs = names.enumerated().map { index, name in
                if name == firstName { return region(name, 1_000, 1_100) }
                if name == secondName { return region(name, 1_099, 1_200) }
                let start = UInt(3_000 + index * 1_000)
                return region(name, start, start + 100)
            }

            XCTAssertNotNil(
                TdtCachedFusionAliasGuard.firstConflict(
                    mutableOutputs: outputs,
                    protectedInputs: []
                ),
                "missed \(firstName) vs \(secondName)"
            )
        }
    }

    func testAliasGuardRejectsInvalidFakeRegion() {
        XCTAssertNotNil(
            TdtCachedFusionAliasGuard.firstConflict(
                mutableOutputs: [region("h_out", 100, 100)],
                protectedInputs: []
            )
        )
    }

    func testPingPongSelectorAlternatesAwayFromRetainedReplayState() {
        let slots = [
            [region("slot0_h", 1_000, 1_100), region("slot0_c", 1_200, 1_300)],
            [region("slot1_h", 2_000, 2_100), region("slot1_c", 2_200, 2_300)],
        ]

        let initialSlot = TdtCachedFusionBackingSelector.selectSlot(
            preferredSlot: 0,
            outputRegionsBySlot: slots,
            protectedInputs: [region("external_h", 9_000, 9_100)]
        )
        XCTAssertEqual(initialSlot, 0)

        let secondSlot = TdtCachedFusionBackingSelector.selectSlot(
            preferredSlot: 1,
            outputRegionsBySlot: slots,
            protectedInputs: [region("current_replay_h", 1_000, 1_100)]
        )
        XCTAssertEqual(secondSlot, 1)

        let thirdSlot = TdtCachedFusionBackingSelector.selectSlot(
            preferredSlot: 0,
            outputRegionsBySlot: slots,
            protectedInputs: [region("current_replay_h", 2_000, 2_100)]
        )
        XCTAssertEqual(thirdSlot, 0)
    }

    func testPingPongSelectorUsesNonPreferredSlotWhenPreferredAliases() {
        let slots = [
            [region("slot0", 1_000, 1_100)],
            [region("slot1", 2_000, 2_100)],
        ]
        XCTAssertEqual(
            TdtCachedFusionBackingSelector.selectSlot(
                preferredSlot: 0,
                outputRegionsBySlot: slots,
                protectedInputs: [region("replay", 1_050, 1_150)]
            ),
            1
        )
    }

    func testPingPongSelectorRejectsWhenBothSlotsAliasReplayInputs() {
        let slots = [
            [region("slot0", 1_000, 1_100)],
            [region("slot1", 2_000, 2_100)],
        ]
        XCTAssertNil(
            TdtCachedFusionBackingSelector.selectSlot(
                preferredSlot: 0,
                outputRegionsBySlot: slots,
                protectedInputs: [
                    region("replay_h", 1_050, 1_150),
                    region("replay_c", 2_050, 2_150),
                ]
            )
        )
    }

    func testBackingIdentityGuardAcceptsOnlyExactNamedRegions() {
        let expected = [
            region("h_out", 1_000, 1_100),
            region("c_out", 2_000, 2_100),
            region("decoder", 3_000, 3_100),
        ]
        XCTAssertNil(
            TdtCachedFusionBackingIdentityGuard.firstMismatch(
                expected: expected,
                actual: [expected[2], expected[0], expected[1]]
            )
        )

        XCTAssertEqual(
            TdtCachedFusionBackingIdentityGuard.firstMismatch(
                expected: expected,
                actual: [
                    expected[0], expected[1], region("decoder", 3_004, 3_104),
                ]
            ),
            .differentRegion("decoder")
        )
    }

    func testBackingIdentityGuardRejectsMissingUnexpectedAndDuplicateNames() {
        let expected = [region("h_out", 1_000, 1_100), region("c_out", 2_000, 2_100)]
        XCTAssertEqual(
            TdtCachedFusionBackingIdentityGuard.firstMismatch(
                expected: expected,
                actual: [region("h_out", 1_000, 1_100)]
            ),
            .missing("c_out")
        )
        XCTAssertEqual(
            TdtCachedFusionBackingIdentityGuard.firstMismatch(
                expected: [expected[0]],
                actual: [expected[0], region("decoder", 3_000, 3_100)]
            ),
            .unexpected("decoder")
        )
        XCTAssertEqual(
            TdtCachedFusionBackingIdentityGuard.firstMismatch(
                expected: expected,
                actual: [expected[0], region("h_out", 4_000, 4_100)]
            ),
            .duplicateActualName("h_out")
        )
    }

    func testBackingPoolAllocatesTwoDistinctStatePairsAndFixedDecisionBuffers() throws {
        let pool = try TdtCachedFusionBackingPool()
        XCTAssertEqual(pool.stateSlots.count, 2)
        XCTAssertEqual(pool.logicalByteCount, 26_124)
        XCTAssertEqual(pool.preferredSlot, 0)

        let first = pool.stateSlots[0]
        let second = pool.stateSlots[1]
        XCTAssertNotEqual(first.hiddenState.dataPointer, second.hiddenState.dataPointer)
        XCTAssertNotEqual(first.cellState.dataPointer, second.cellState.dataPointer)
        XCTAssertNotEqual(first.decoderProjection.dataPointer, second.decoderProjection.dataPointer)
        XCTAssertEqual(first.hiddenState.count, 1_280)
        XCTAssertEqual(first.cellState.count, 1_280)
        XCTAssertEqual(first.decoderProjection.count, 640)
        XCTAssertEqual(pool.topKIds.count, 64)
        XCTAssertEqual(pool.topKLogits.count, 64)

        pool.markSelected(slot: 0)
        XCTAssertEqual(pool.preferredSlot, 1)
        pool.markSelected(slot: 1)
        XCTAssertEqual(pool.preferredSlot, 0)
    }

    private func region(
        _ name: String,
        _ lowerBound: UInt,
        _ upperBound: UInt
    ) -> TdtCachedFusionMemoryRegion {
        TdtCachedFusionMemoryRegion(
            name: name,
            lowerBound: lowerBound,
            upperBound: upperBound
        )
    }
}
