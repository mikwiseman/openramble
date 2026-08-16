import Foundation
import XCTest

@testable import FluidAudio

final class ASRClosedWindowCacheTests: XCTestCase {
    func testCachingIsGatedToV3NoMelSingleDecode() {
        XCTAssertTrue(
            ASRClosedWindowValidation.supportsCaching(
                modelVersion: .v3,
                melChunkContext: false,
                dualDecodeArbitration: false
            )
        )
        XCTAssertFalse(
            ASRClosedWindowValidation.supportsCaching(
                modelVersion: .v3,
                melChunkContext: true,
                dualDecodeArbitration: false
            )
        )
        XCTAssertFalse(
            ASRClosedWindowValidation.supportsCaching(
                modelVersion: .v3,
                melChunkContext: false,
                dualDecodeArbitration: true
            )
        )
        XCTAssertFalse(
            ASRClosedWindowValidation.supportsCaching(
                modelVersion: .v2,
                melChunkContext: false,
                dualDecodeArbitration: false
            )
        )
    }

    func testFirstWindowRequiresLongFormRouteAndOneSamplePastEnd() throws {
        let atRouteBoundary = ChunkProcessor(
            audioSamples: [Float](repeating: 0, count: ASRConstants.maxModelSamples)
        )
        let boundaryPlans = try atRouteBoundary.closedWindowPlans(
            melChunkContext: false,
            modelVersion: .v3
        )
        XCTAssertEqual(boundaryPlans[0].earliestSafePrefixSampleCount, ASRConstants.maxModelSamples + 1)
        XCTAssertGreaterThan(boundaryPlans[0].earliestSafePrefixSampleCount, atRouteBoundary.totalSamples)

        let firstSafePrefix = ChunkProcessor(
            audioSamples: [Float](repeating: 0, count: ASRConstants.maxModelSamples + 1)
        )
        let safePlans = try firstSafePrefix.closedWindowPlans(
            melChunkContext: false,
            modelVersion: .v3
        )
        XCTAssertFalse(safePlans[0].isLastChunk)
        XCTAssertEqual(safePlans[0].chunkStart, 0)
        XCTAssertEqual(safePlans[0].chunkEnd, 239_360)
        XCTAssertEqual(safePlans[0].earliestSafePrefixSampleCount, firstSafePrefix.totalSamples)
    }

    func testClosedPlanIsStableAtItsClaimedPrefix() throws {
        let complete = [Float](repeating: 0, count: 30 * ASRConstants.sampleRate)
        let finalPlans = try ChunkProcessor(audioSamples: complete).closedWindowPlans(
            melChunkContext: false,
            modelVersion: .v3
        )
        let finalPlan = try XCTUnwrap(finalPlans.first(where: { $0.index == 1 && !$0.isLastChunk }))
        let prefix = Array(complete.prefix(finalPlan.earliestSafePrefixSampleCount))
        let prefixPlans = try ChunkProcessor(audioSamples: prefix).closedWindowPlans(
            melChunkContext: false,
            modelVersion: .v3
        )

        XCTAssertEqual(prefixPlans[finalPlan.index], finalPlan)
        XCTAssertFalse(prefixPlans[finalPlan.index].isLastChunk)
    }

    func testEveryExposedRecursivePlanSurvivesAdversarialFutureExtensions() throws {
        let fixture = makeAdversarialPlannerFixture(seconds: 120)
        let referencePlans = try ChunkProcessor(audioSamples: fixture).closedWindowPlans(
            melChunkContext: false,
            modelVersion: .v3
        )
        let referenceClosedPlans = Array(referencePlans.filter { !$0.isLastChunk }.prefix(6))
        XCTAssertGreaterThanOrEqual(referenceClosedPlans.count, 6)

        let frameSamples = ASRConstants.samplesPerEncoderFrame
        let suffixes: [[Float]] = [
            makeSuffix(count: 1, mode: .silence),
            makeSuffix(count: frameSamples - 1, mode: .speech),
            makeSuffix(count: frameSamples, mode: .alternatingValleys),
            makeSuffix(count: frameSamples + 1, mode: .speech),
            makeSuffix(count: 4 * ASRConstants.sampleRate + frameSamples, mode: .silence),
            makeSuffix(count: 17 * ASRConstants.sampleRate, mode: .alternatingValleys),
            makeSuffix(count: 33 * ASRConstants.sampleRate, mode: .speech),
        ]

        for reference in referenceClosedPlans {
            let prefixCounts = Set([
                reference.earliestSafePrefixSampleCount,
                reference.earliestSafePrefixSampleCount + 1,
                reference.earliestSafePrefixSampleCount + frameSamples - 1,
                reference.earliestSafePrefixSampleCount + frameSamples,
            ]).filter { $0 <= fixture.count }

            for prefixCount in prefixCounts {
                let prefix = Array(fixture.prefix(prefixCount))
                let prefixPlans = try ChunkProcessor(audioSamples: prefix).closedWindowPlans(
                    melChunkContext: false,
                    modelVersion: .v3
                )
                let exposed = prefixPlans.filter {
                    !$0.isLastChunk && $0.earliestSafePrefixSampleCount <= prefixCount
                }
                let descriptor = try XCTUnwrap(
                    exposed.first(where: { $0.index == reference.index }),
                    "reference window \(reference.index) was not exposed at its claimed bound"
                )
                XCTAssertEqual(
                    descriptor,
                    reference,
                    "recursive prior boundary changed at prefix \(prefixCount)"
                )

                for suffix in suffixes {
                    let extended = prefix + suffix
                    let extendedPlans = try ChunkProcessor(audioSamples: extended).closedWindowPlans(
                        melChunkContext: false,
                        modelVersion: .v3
                    )
                    XCTAssertGreaterThan(extendedPlans.count, descriptor.index)
                    XCTAssertEqual(
                        extendedPlans[descriptor.index],
                        descriptor,
                        "future energy changed closed window \(descriptor.index); prefix=\(prefixCount) suffix=\(suffix.count)"
                    )
                }
            }
        }
    }

    func testExposureBoundCoversSearchRightEdgeEnergyWindowAndRecursiveTargets() throws {
        let fixture = makeAdversarialPlannerFixture(seconds: 120)
        let processor = ChunkProcessor(audioSamples: fixture)
        let layout = processor.chunkLayoutForTesting(
            melChunkContext: false,
            modelVersion: .v3
        )
        let plans = try processor.closedWindowPlans(
            melChunkContext: false,
            modelVersion: .v3
        )
        let frameSamples = ASRConstants.samplesPerEncoderFrame
        let radiusFrames = Int(
            (4.0 * Double(ASRConstants.sampleRate)) / Double(frameSamples)
        )

        for descriptor in plans.filter({ !$0.isLastChunk }).prefix(6) {
            if descriptor.index > 0 {
                let recursiveTargetFrame = descriptor.index * layout.strideSamples / frameSamples
                let completeRightEnergyWindow =
                    (recursiveTargetFrame + radiusFrames) * frameSamples + frameSamples
                XCTAssertGreaterThanOrEqual(
                    descriptor.earliestSafePrefixSampleCount,
                    completeRightEnergyWindow,
                    "target + 4s candidate's right 1,280-sample energy half-window is not complete"
                )
            }
            XCTAssertGreaterThan(
                descriptor.earliestSafePrefixSampleCount,
                descriptor.chunkEnd,
                "a window cannot be final-plan-stable until one authoritative sample exists past its end"
            )

            let oneSampleEarly = descriptor.earliestSafePrefixSampleCount - 1
            let earlyPlans = try ChunkProcessor(
                audioSamples: Array(fixture.prefix(oneSampleEarly))
            ).closedWindowPlans(melChunkContext: false, modelVersion: .v3)
            let earlyDescriptor = earlyPlans.first(where: { $0.index == descriptor.index })
            XCTAssertFalse(
                earlyDescriptor.map {
                    !$0.isLastChunk && $0.earliestSafePrefixSampleCount <= oneSampleEarly
                } ?? false,
                "descriptor \(descriptor.index) was exposed one sample before its proof bound"
            )
        }
    }

    func testValidatorPreservesEveryRawTokenField() throws {
        let fixture = makeFixture()
        let validated = ASRClosedWindowValidation.validatedWindows(
            caches: [fixture.cache],
            expectedOwner: fixture.owner,
            languageRawValue: "en",
            finalPlans: fixture.finalPlans,
            finalSamples: fixture.finalSamples
        )
        let token = try XCTUnwrap(validated[0]?.tokens.first)

        XCTAssertEqual(token.token, 17)
        XCTAssertEqual(token.timestamp, 23)
        XCTAssertEqual(token.confidence.bitPattern, Float(0.75).bitPattern)
        XCTAssertEqual(token.duration, 4)
    }

    func testValidatorFallsBackAfterOneBitInputMutation() {
        let fixture = makeFixture()
        var finalSamples = fixture.finalSamples
        finalSamples[2] = Float(bitPattern: finalSamples[2].bitPattern ^ 1)

        let validated = ASRClosedWindowValidation.validatedWindows(
            caches: [fixture.cache],
            expectedOwner: fixture.owner,
            languageRawValue: "en",
            finalPlans: fixture.finalPlans,
            finalSamples: finalSamples
        )
        XCTAssertTrue(validated.isEmpty)
    }

    func testValidatorRejectsEveryDuplicateIndex() {
        let fixture = makeFixture()
        let validated = ASRClosedWindowValidation.validatedWindows(
            caches: [fixture.cache, fixture.cache],
            expectedOwner: fixture.owner,
            languageRawValue: "en",
            finalPlans: fixture.finalPlans,
            finalSamples: fixture.finalSamples
        )
        XCTAssertTrue(validated.isEmpty)
    }

    func testValidatorRejectsMisalignedDurationArrayInsteadOfFillingZeros() {
        let fixture = makeFixture()
        let malformed = ASRClosedWindowCache(
            owner: fixture.cache.owner,
            languageRawValue: fixture.cache.languageRawValue,
            descriptor: fixture.cache.descriptor,
            inputSamples: fixture.cache.inputSamples,
            tokenIDs: fixture.cache.tokenIDs,
            timestamps: fixture.cache.timestamps,
            confidences: fixture.cache.confidences,
            durations: []
        )

        let validated = ASRClosedWindowValidation.validatedWindows(
            caches: [malformed],
            expectedOwner: fixture.owner,
            languageRawValue: "en",
            finalPlans: fixture.finalPlans,
            finalSamples: fixture.finalSamples
        )
        XCTAssertTrue(validated.isEmpty)
    }

    func testValidatorFencesManagerEpochLanguageAndFinalWindows() {
        let fixture = makeFixture()
        let nextEpoch = ASRClosedWindowOwner(
            managerIdentifier: fixture.owner.managerIdentifier,
            managerEpoch: fixture.owner.managerEpoch + 1
        )
        XCTAssertTrue(
            ASRClosedWindowValidation.validatedWindows(
                caches: [fixture.cache],
                expectedOwner: nextEpoch,
                languageRawValue: "en",
                finalPlans: fixture.finalPlans,
                finalSamples: fixture.finalSamples
            ).isEmpty
        )
        XCTAssertTrue(
            ASRClosedWindowValidation.validatedWindows(
                caches: [fixture.cache],
                expectedOwner: fixture.owner,
                languageRawValue: "ru",
                finalPlans: fixture.finalPlans,
                finalSamples: fixture.finalSamples
            ).isEmpty
        )

        let finalDescriptor = ASRClosedWindowDescriptor(
            index: 0,
            chunkStart: 0,
            contextStart: 0,
            chunkEnd: 4,
            contextSamples: 0,
            chunkStartOffset: 0,
            isLastChunk: true,
            emitTokensAfterFrame: nil,
            initialTimeIndexOverride: nil,
            stableThroughSampleCount: 0,
            earliestSafePrefixSampleCount: 5
        )
        let finalCache = ASRClosedWindowCache(
            owner: fixture.owner,
            languageRawValue: "en",
            descriptor: finalDescriptor,
            inputSamples: Array(fixture.finalSamples.prefix(4)),
            tokenIDs: [17],
            timestamps: [23],
            confidences: [0.75],
            durations: [4]
        )
        XCTAssertTrue(
            ASRClosedWindowValidation.validatedWindows(
                caches: [finalCache],
                expectedOwner: fixture.owner,
                languageRawValue: "en",
                finalPlans: [finalDescriptor],
                finalSamples: fixture.finalSamples
            ).isEmpty
        )
    }

    func testPrecomputeOwnerFenceRejectsEpochChangedAcrossInferenceSuspension() {
        let fixture = makeFixture()
        let resetOwner = ASRClosedWindowOwner(
            managerIdentifier: fixture.owner.managerIdentifier,
            managerEpoch: fixture.owner.managerEpoch + 1
        )

        XCTAssertEqual(
            ASRClosedWindowValidation.ownerAfterInference(
                expected: fixture.owner,
                current: fixture.owner
            ),
            fixture.owner
        )
        XCTAssertNil(
            ASRClosedWindowValidation.ownerAfterInference(
                expected: fixture.owner,
                current: resetOwner
            ),
            "reset/load during the awaited model call must discard its stale output"
        )
    }

    func testFinalReuseBarrierRejectsEpochChangedAfterValidation() {
        let fixture = makeFixture()
        let reloadedOwner = ASRClosedWindowOwner(
            managerIdentifier: fixture.owner.managerIdentifier,
            managerEpoch: fixture.owner.managerEpoch + 1
        )

        XCTAssertTrue(
            ASRClosedWindowValidation.finalResultMayReuseCache(
                expected: fixture.owner,
                current: fixture.owner
            )
        )
        XCTAssertFalse(
            ASRClosedWindowValidation.finalResultMayReuseCache(
                expected: fixture.owner,
                current: reloadedOwner
            ),
            "a model change after validation must discard the cached candidate and rerun normally"
        )
    }

    private func makeFixture() -> (
        owner: ASRClosedWindowOwner,
        cache: ASRClosedWindowCache,
        finalPlans: [ASRClosedWindowDescriptor],
        finalSamples: [Float]
    ) {
        let owner = ASRClosedWindowOwner(
            managerIdentifier: UUID(),
            managerEpoch: 7
        )
        let descriptor = ASRClosedWindowDescriptor(
            index: 0,
            chunkStart: 0,
            contextStart: 0,
            chunkEnd: 4,
            contextSamples: 0,
            chunkStartOffset: 0,
            isLastChunk: false,
            emitTokensAfterFrame: nil,
            initialTimeIndexOverride: nil,
            stableThroughSampleCount: 0,
            earliestSafePrefixSampleCount: 5
        )
        let finalDescriptor = ASRClosedWindowDescriptor(
            index: 1,
            chunkStart: 2,
            contextStart: 2,
            chunkEnd: 6,
            contextSamples: 0,
            chunkStartOffset: 2,
            isLastChunk: true,
            emitTokensAfterFrame: nil,
            initialTimeIndexOverride: nil,
            stableThroughSampleCount: 0,
            earliestSafePrefixSampleCount: 7
        )
        let finalSamples: [Float] = [0, -0.0, 0.25, -0.5, 0.75, -1]
        let cache = ASRClosedWindowCache(
            owner: owner,
            languageRawValue: "en",
            descriptor: descriptor,
            inputSamples: Array(finalSamples.prefix(4)),
            tokenIDs: [17],
            timestamps: [23],
            confidences: [0.75],
            durations: [4]
        )
        return (owner, cache, [descriptor, finalDescriptor], finalSamples)
    }

    private enum SuffixMode {
        case silence
        case speech
        case alternatingValleys
    }

    private func makeSuffix(count: Int, mode: SuffixMode) -> [Float] {
        switch mode {
        case .silence:
            return [Float](repeating: 0, count: count)
        case .speech:
            return (0..<count).map { $0.isMultiple(of: 2) ? 0.9 : -0.9 }
        case .alternatingValleys:
            let frameSamples = ASRConstants.samplesPerEncoderFrame
            return (0..<count).map { index in
                let frame = index / frameSamples
                if frame.isMultiple(of: 7) { return 0 }
                return index.isMultiple(of: 2) ? 0.35 : -0.35
            }
        }
    }

    private func makeAdversarialPlannerFixture(seconds: Int) -> [Float] {
        let count = seconds * ASRConstants.sampleRate
        let frameSamples = ASRConstants.samplesPerEncoderFrame
        var samples = (0..<count).map { index in
            index.isMultiple(of: 2) ? Float(0.22) : Float(-0.22)
        }
        let processor = ChunkProcessor(audioSamples: samples)
        let layout = processor.chunkLayoutForTesting(
            melChunkContext: false,
            modelVersion: .v3
        )
        let radiusFrames = Int(
            (4.0 * Double(ASRConstants.sampleRate)) / Double(frameSamples)
        )

        // Alternate deterministic valleys at target - 4s, target + 4s, and
        // target itself. Later targets therefore depend on prior aligned starts
        // instead of exercising only regular zero-audio strides.
        for index in 1...8 {
            let target = index * layout.strideSamples
            let offsetFrames: Int
            switch index % 3 {
            case 0: offsetFrames = -radiusFrames
            case 1: offsetFrames = radiusFrames
            default: offsetFrames = 0
            }
            let center = target + offsetFrames * frameSamples
            let lower = max(0, center - frameSamples)
            let upper = min(samples.count, center + frameSamples)
            if lower < upper {
                for sampleIndex in lower..<upper {
                    samples[sampleIndex] = 0
                }
            }

            let shoulderCenter = target - (radiusFrames - 1) * frameSamples
            let shoulderLower = max(0, shoulderCenter - frameSamples / 2)
            let shoulderUpper = min(samples.count, shoulderCenter + frameSamples / 2)
            if shoulderLower < shoulderUpper {
                for sampleIndex in shoulderLower..<shoulderUpper {
                    samples[sampleIndex] = sampleIndex.isMultiple(of: 2) ? 0.015 : -0.015
                }
            }
        }
        return samples
    }
}
