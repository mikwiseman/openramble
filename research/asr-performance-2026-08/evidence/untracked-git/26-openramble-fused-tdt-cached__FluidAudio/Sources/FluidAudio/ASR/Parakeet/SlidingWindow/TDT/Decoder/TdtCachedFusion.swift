@preconcurrency import CoreML
import Foundation

/// Static schema and host-side scheduling rules for the optional v3 cached-decoder fusion.
///
/// The fused graph is deliberately not a replacement for every joint call. It is used only
/// when the shipping path must advance the prediction network (SOS or an accepted non-blank)
/// and an encoder frame for the immediately following joint decision is available. Blank
/// streaks continue through the shipping joint-only path with the cached decoder projection.
internal enum TdtCachedFusionContract {
    static let topKCount = 64
    static let decoderHiddenSize = 640
    static let decoderLayerCount = 2

    private struct TensorSpec {
        let shape: [Int]
        let dataType: MLMultiArrayDataType
    }

    private static let inputSpecs: [String: TensorSpec] = [
        "targets": TensorSpec(shape: [1, 1], dataType: .int32),
        "target_length": TensorSpec(shape: [1], dataType: .int32),
        "h_in": TensorSpec(shape: [decoderLayerCount, 1, decoderHiddenSize], dataType: .float32),
        "c_in": TensorSpec(shape: [decoderLayerCount, 1, decoderHiddenSize], dataType: .float32),
        "encoder_step": TensorSpec(shape: [1, 1024, 1], dataType: .float32),
    ]

    private static let outputSpecs: [String: TensorSpec] = [
        "token_id": TensorSpec(shape: [1, 1, 1], dataType: .int32),
        "token_prob": TensorSpec(shape: [1, 1, 1], dataType: .float32),
        "duration": TensorSpec(shape: [1, 1, 1], dataType: .int32),
        "top_k_ids": TensorSpec(shape: [1, 1, 1, topKCount], dataType: .int32),
        "top_k_logits": TensorSpec(shape: [1, 1, 1, topKCount], dataType: .float32),
        "decoder": TensorSpec(shape: [1, decoderHiddenSize, 1], dataType: .float32),
        "h_out": TensorSpec(shape: [decoderLayerCount, 1, decoderHiddenSize], dataType: .float32),
        "c_out": TensorSpec(shape: [decoderLayerCount, 1, decoderHiddenSize], dataType: .float32),
    ]

    /// Fail closed on any feature-name, shape, or dtype drift before the optional path is used.
    static func validate(model: MLModel) throws {
        try validate(
            descriptions: model.modelDescription.inputDescriptionsByName,
            expected: inputSpecs,
            kind: "input"
        )
        try validate(
            descriptions: model.modelDescription.outputDescriptionsByName,
            expected: outputSpecs,
            kind: "output"
        )
    }

    private static func validate(
        descriptions: [String: MLFeatureDescription],
        expected: [String: TensorSpec],
        kind: String
    ) throws {
        let actualNames = Set(descriptions.keys)
        let expectedNames = Set(expected.keys)
        guard actualNames == expectedNames else {
            throw ASRError.processingFailed(
                "Cached fused \(kind) names mismatch: \(actualNames.sorted()) != \(expectedNames.sorted())"
            )
        }

        for (name, spec) in expected {
            guard let constraint = descriptions[name]?.multiArrayConstraint else {
                throw ASRError.processingFailed("Cached fused \(kind) \(name) is not a multi-array")
            }
            let shape = constraint.shape.map(\.intValue)
            guard shape == spec.shape, constraint.dataType == spec.dataType else {
                throw ASRError.processingFailed(
                    "Cached fused \(kind) \(name) mismatch: \(shape)/\(constraint.dataType.rawValue)"
                )
            }
        }
    }
}

/// Conservative byte span used to prove that a fused candidate cannot overwrite a replay input.
///
/// The span deliberately covers stride gaps. That can reject an unusual non-contiguous layout,
/// but it cannot miss a partial overlap between two views into the same backing allocation.
internal struct TdtCachedFusionMemoryRegion: Equatable, Sendable {
    let name: String
    let lowerBound: UInt
    let upperBound: UInt

    init(name: String, lowerBound: UInt, upperBound: UInt) {
        self.name = name
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    var isValid: Bool { lowerBound < upperBound }

    func overlaps(_ other: Self) -> Bool {
        lowerBound < other.upperBound && other.lowerBound < upperBound
    }
}

internal struct TdtCachedFusionAliasConflict: Equatable, Sendable {
    let mutableOutput: String
    let otherRegion: String
}

/// Pure alias check kept separate from CoreML so every cross-alias can be tested with fake spans.
internal enum TdtCachedFusionAliasGuard {
    static func firstConflict(
        mutableOutputs: [TdtCachedFusionMemoryRegion],
        protectedInputs: [TdtCachedFusionMemoryRegion]
    ) -> TdtCachedFusionAliasConflict? {
        for (index, output) in mutableOutputs.enumerated() {
            guard output.isValid else {
                return TdtCachedFusionAliasConflict(
                    mutableOutput: output.name,
                    otherRegion: "invalid-region"
                )
            }

            for otherOutput in mutableOutputs.dropFirst(index + 1) {
                guard otherOutput.isValid else {
                    return TdtCachedFusionAliasConflict(
                        mutableOutput: otherOutput.name,
                        otherRegion: "invalid-region"
                    )
                }
                if output.overlaps(otherOutput) {
                    return TdtCachedFusionAliasConflict(
                        mutableOutput: output.name,
                        otherRegion: otherOutput.name
                    )
                }
            }

            for protectedInput in protectedInputs {
                guard protectedInput.isValid else {
                    return TdtCachedFusionAliasConflict(
                        mutableOutput: output.name,
                        otherRegion: "invalid-region:\(protectedInput.name)"
                    )
                }
                if output.overlaps(protectedInput) {
                    return TdtCachedFusionAliasConflict(
                        mutableOutput: output.name,
                        otherRegion: protectedInput.name
                    )
                }
            }
        }
        return nil
    }
}

/// Pure two-slot selection. The preferred slot is used only when every one of its output
/// backings is disjoint from the state/input regions that must remain replayable.
internal enum TdtCachedFusionBackingSelector {
    static func selectSlot(
        preferredSlot: Int,
        outputRegionsBySlot: [[TdtCachedFusionMemoryRegion]],
        protectedInputs: [TdtCachedFusionMemoryRegion]
    ) -> Int? {
        guard outputRegionsBySlot.count == 2, (0..<2).contains(preferredSlot) else { return nil }
        for slot in [preferredSlot, 1 - preferredSlot]
        where TdtCachedFusionAliasGuard.firstConflict(
            mutableOutputs: outputRegionsBySlot[slot],
            protectedInputs: protectedInputs
        ) == nil {
            return slot
        }
        return nil
    }
}

internal enum TdtCachedFusionBackingIdentityMismatch: Equatable, Sendable {
    case duplicateExpectedName(String)
    case duplicateActualName(String)
    case missing(String)
    case unexpected(String)
    case differentRegion(String)
}

/// Pure exact-backing check. Runtime shape/dtype/stride checks are performed before this helper;
/// matching the byte region proves CoreML honored the selected output backing rather than
/// returning a detached or input-aliased allocation.
internal enum TdtCachedFusionBackingIdentityGuard {
    static func firstMismatch(
        expected: [TdtCachedFusionMemoryRegion],
        actual: [TdtCachedFusionMemoryRegion]
    ) -> TdtCachedFusionBackingIdentityMismatch? {
        let expectedNames = expected.map(\.name)
        let actualNames = actual.map(\.name)
        if let duplicate = firstDuplicate(in: expectedNames) {
            return .duplicateExpectedName(duplicate)
        }
        if let duplicate = firstDuplicate(in: actualNames) {
            return .duplicateActualName(duplicate)
        }

        let expectedByName = Dictionary(uniqueKeysWithValues: expected.map { ($0.name, $0) })
        let actualByName = Dictionary(uniqueKeysWithValues: actual.map { ($0.name, $0) })
        for name in expectedNames where actualByName[name] == nil { return .missing(name) }
        for name in actualNames where expectedByName[name] == nil { return .unexpected(name) }
        for name in expectedNames {
            guard let expectedRegion = expectedByName[name], let actualRegion = actualByName[name]
            else { return .missing(name) }
            if expectedRegion.lowerBound != actualRegion.lowerBound
                || expectedRegion.upperBound != actualRegion.upperBound
            {
                return .differentRegion(name)
            }
        }
        return nil
    }

    private static func firstDuplicate(in names: [String]) -> String? {
        var seen: Set<String> = []
        for name in names where !seen.insert(name).inserted { return name }
        return nil
    }
}

internal struct TdtCachedFusionStateBackingSet: Sendable {
    let slot: Int
    let hiddenState: MLMultiArray
    let cellState: MLMultiArray
    let decoderProjection: MLMultiArray
}

/// Per-decode two-pair backing pool. A selected candidate writes only into the slot that is
/// disjoint from its replay input. After the candidate is consumed, that slot becomes current
/// state and the next fused call necessarily selects the other pair.
internal final class TdtCachedFusionBackingPool: @unchecked Sendable {
    let stateSlots: [TdtCachedFusionStateBackingSet]
    let tokenId: MLMultiArray
    let tokenProbability: MLMultiArray
    let duration: MLMultiArray
    let topKIds: MLMultiArray
    let topKLogits: MLMultiArray
    private(set) var preferredSlot = 0

    init() throws {
        stateSlots = try (0..<2).map { slot in
            TdtCachedFusionStateBackingSet(
                slot: slot,
                hiddenState: try ANEMemoryUtils.createAlignedArray(
                    shape: [
                        NSNumber(value: TdtCachedFusionContract.decoderLayerCount), 1,
                        NSNumber(value: TdtCachedFusionContract.decoderHiddenSize),
                    ],
                    dataType: .float32
                ),
                cellState: try ANEMemoryUtils.createAlignedArray(
                    shape: [
                        NSNumber(value: TdtCachedFusionContract.decoderLayerCount), 1,
                        NSNumber(value: TdtCachedFusionContract.decoderHiddenSize),
                    ],
                    dataType: .float32
                ),
                decoderProjection: try ANEMemoryUtils.createAlignedArray(
                    shape: [1, NSNumber(value: TdtCachedFusionContract.decoderHiddenSize), 1],
                    dataType: .float32
                )
            )
        }
        tokenId = try MLMultiArray(shape: [1, 1, 1], dataType: .int32)
        tokenProbability = try MLMultiArray(shape: [1, 1, 1], dataType: .float32)
        duration = try MLMultiArray(shape: [1, 1, 1], dataType: .int32)
        topKIds = try MLMultiArray(
            shape: [1, 1, 1, NSNumber(value: TdtCachedFusionContract.topKCount)],
            dataType: .int32
        )
        topKLogits = try MLMultiArray(
            shape: [1, 1, 1, NSNumber(value: TdtCachedFusionContract.topKCount)],
            dataType: .float32
        )
    }

    func markSelected(slot: Int) {
        precondition((0..<2).contains(slot))
        preferredSlot = 1 - slot
    }

    var logicalByteCount: UInt64 {
        let stateFloats = stateSlots.reduce(0) {
            $0 + $1.hiddenState.count + $1.cellState.count + $1.decoderProjection.count
        }
        let scalarBytes =
            tokenId.count * MemoryLayout<Int32>.size
            + tokenProbability.count * MemoryLayout<Float>.size
            + duration.count * MemoryLayout<Int32>.size
        let topKBytes =
            topKIds.count * MemoryLayout<Int32>.size
            + topKLogits.count * MemoryLayout<Float>.size
        return UInt64(stateFloats * MemoryLayout<Float>.size + scalarBytes + topKBytes)
    }
}

/// A completely validated fused prediction that has not yet changed decoder-visible state.
///
/// `replayState` and `replayToken` preserve the exact A-path inputs. If the promised decision
/// frame is no longer current, the candidate is discarded and those inputs are replayed through
/// the separate shipping decoder before calling the shipping joint.
internal struct TdtCachedFusedStep {
    let decoderState: TdtDecoderState
    let predictorOutput: MLMultiArray
    let decision: TdtJointDecision
    let decisionFrame: Int
    let replayState: TdtDecoderState
    let replayToken: Int
    let timing: TdtCachedFusedCallTiming
}

internal struct TdtCachedFusedCallTiming: Equatable, Sendable {
    let totalWallNanoseconds: UInt64
    let predictionWallNanoseconds: UInt64
    let hostBeforePredictionNanoseconds: UInt64
    let hostValidationNanoseconds: UInt64
    let detachedStateLogicalBytes: UInt64
    let preallocatedStateLogicalBytesWritten: UInt64
    let finiteScanWallNanoseconds: UInt64
    let backingSlot: Int
}

internal enum TdtCachedFusionDecoderOnlyReason: Equatable, Sendable {
    case noFusedArtifact
    case noFollowingEncoderFrame
    case lastChunkFlush
    case fusedFailure
    case prefetchedFrameMismatch
}

internal enum TdtCachedFusionScheduledWork: Equatable, Sendable {
    case fusedDecoderAndJoint(frame: Int)
    case decoderOnly(TdtCachedFusionDecoderOnlyReason)
    case jointOnly(frame: Int)
    case stop
}

/// Pure scheduling surface used by both the decoder and deterministic transition tests.
internal enum TdtCachedFusionScheduler {
    static func afterDecoderToken(
        fusedAvailable: Bool,
        nextEncoderFrame: Int?,
        isLastChunkFlush: Bool = false,
        tokenLimitExceeded: Bool = false
    ) -> TdtCachedFusionScheduledWork {
        guard !tokenLimitExceeded else { return .stop }
        guard !isLastChunkFlush else { return .decoderOnly(.lastChunkFlush) }
        guard fusedAvailable else { return .decoderOnly(.noFusedArtifact) }
        guard let nextEncoderFrame else { return .decoderOnly(.noFollowingEncoderFrame) }
        return .fusedDecoderAndJoint(frame: nextEncoderFrame)
    }

    static func forBlankCacheHit(frame: Int) -> TdtCachedFusionScheduledWork {
        .jointOnly(frame: frame)
    }
}

/// Runs the final cancellation/error check before publishing one aggregate candidate value.
/// A throwing `beforeCommit` closure leaves `current` byte-for-byte unchanged.
internal struct TdtCachedFusionAtomicCandidate<Value> {
    let value: Value

    func commit(into current: inout Value, beforeCommit: () throws -> Void) rethrows {
        try beforeCommit()
        current = value
    }
}

/// Small call/state trace attached to a hypothesis for exact A/B accounting.
public struct TdtCachedFusionDiagnostics: Codable, Equatable, Sendable {
    public internal(set) var fusedSOSCalls = 0
    public internal(set) var fusedTokenCalls = 0
    public internal(set) var prefetchedDecisionsConsumed = 0
    public internal(set) var separateDecoderCalls = 0
    public internal(set) var jointOnlyCalls = 0
    public internal(set) var fallbacks = 0
    public internal(set) var prefetchedFrameMismatches = 0
    public internal(set) var decoderOnlyAtBoundary = 0
    public internal(set) var decoderOnlyInLastChunkFlush = 0
    public internal(set) var schemaValidationCalls = 0
    public internal(set) var schemaValidationWallNanoseconds: UInt64 = 0
    public internal(set) var separateDecoderWallNanoseconds: UInt64 = 0
    public internal(set) var jointOnlyWallNanoseconds: UInt64 = 0
    public internal(set) var fusedTotalWallNanoseconds: UInt64 = 0
    public internal(set) var fusedPredictionWallNanoseconds: UInt64 = 0
    public internal(set) var fusedHostBeforePredictionNanoseconds: UInt64 = 0
    public internal(set) var fusedHostValidationNanoseconds: UInt64 = 0
    public internal(set) var fusedDetachedStateLogicalBytes: UInt64 = 0
    public internal(set) var fusedPreallocatedStateLogicalBytesWritten: UInt64 = 0
    public internal(set) var fusedFiniteScanWallNanoseconds: UInt64 = 0
    public internal(set) var backingIdentityValidations = 0
    public internal(set) var backingSlot0Calls = 0
    public internal(set) var backingSlot1Calls = 0
    public internal(set) var backingPoolAllocations = 0
    public internal(set) var backingPoolAllocationWallNanoseconds: UInt64 = 0
    public internal(set) var backingPoolLogicalBytes: UInt64 = 0

    mutating func record(_ timing: TdtCachedFusedCallTiming) {
        fusedTotalWallNanoseconds += timing.totalWallNanoseconds
        fusedPredictionWallNanoseconds += timing.predictionWallNanoseconds
        fusedHostBeforePredictionNanoseconds += timing.hostBeforePredictionNanoseconds
        fusedHostValidationNanoseconds += timing.hostValidationNanoseconds
        fusedDetachedStateLogicalBytes += timing.detachedStateLogicalBytes
        fusedPreallocatedStateLogicalBytesWritten += timing.preallocatedStateLogicalBytesWritten
        fusedFiniteScanWallNanoseconds += timing.finiteScanWallNanoseconds
        backingIdentityValidations += 1
        if timing.backingSlot == 0 {
            backingSlot0Calls += 1
        } else {
            backingSlot1Calls += 1
        }
    }
}
