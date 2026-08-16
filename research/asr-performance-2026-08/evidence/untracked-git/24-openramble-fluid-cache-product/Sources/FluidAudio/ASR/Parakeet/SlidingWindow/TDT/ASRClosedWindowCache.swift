import Foundation

/// A non-final long-form window whose input range and boundary decision are
/// proven immutable for every future extension of the supplied audio prefix.
///
/// Plans are opaque capabilities. They can only be created by the manager that
/// owns the loaded model epoch and are revalidated before inference and reuse.
public struct ASRClosedWindowPlan: Sendable {
    let owner: ASRClosedWindowOwner
    let descriptor: ASRClosedWindowDescriptor

    public var index: Int { descriptor.index }
    public var inputStartSample: Int { descriptor.contextStart }
    public var inputEndSample: Int { descriptor.chunkEnd }
    public var earliestSafePrefixSampleCount: Int { descriptor.earliestSafePrefixSampleCount }
}

/// One bounded planner result. `nextPlanningSampleCount` is a conservative,
/// exact-safe watermark: no caller needs to rescan the growing prefix before
/// that count can make another final-plan-stable window available.
public struct ASRClosedWindowPlanningSnapshot: Sendable {
    public let plans: [ASRClosedWindowPlan]
    public let nextPlanningSampleCount: Int?

    init(plans: [ASRClosedWindowPlan], nextPlanningSampleCount: Int?) {
        self.plans = plans
        self.nextPlanningSampleCount = nextPlanningSampleCount
    }
}

/// Exact model input detached from the growing recording before inference.
/// Holding this value across an awaited model call retains one bounded window,
/// never the complete long-form prefix that proved the plan.
public struct ASRPreparedClosedWindow: Sendable {
    let owner: ASRClosedWindowOwner
    let language: Language?
    let descriptor: ASRClosedWindowDescriptor
    let inputSamples: [Float]

    public var index: Int { descriptor.index }
    public var inputSampleCount: Int { inputSamples.count }
}

/// Opaque raw output of one exact non-final long-form window.
///
/// The cache contains decoder tokens before merge, text conversion, timing
/// construction, and any vocabulary rescoring. Callers can inspect bounded
/// metadata but cannot construct or mutate cache contents.
public struct ASRClosedWindowCache: Sendable {
    let owner: ASRClosedWindowOwner
    let languageRawValue: String?
    let descriptor: ASRClosedWindowDescriptor
    let inputSamples: [Float]
    let tokenIDs: [Int]
    let timestamps: [Int]
    let confidences: [Float]
    let durations: [Int]

    public var index: Int { descriptor.index }
    public var inputStartSample: Int { descriptor.contextStart }
    public var inputEndSample: Int { descriptor.chunkEnd }
    public var inputSampleCount: Int { descriptor.inputSampleCount }
    public var tokenCount: Int { tokenIDs.count }
}

struct ASRClosedWindowOwner: Sendable, Equatable {
    let managerIdentifier: UUID
    let managerEpoch: UInt64
}

struct ASRClosedWindowDescriptor: Sendable, Equatable {
    let index: Int
    let chunkStart: Int
    let contextStart: Int
    let chunkEnd: Int
    let contextSamples: Int
    let chunkStartOffset: Int
    let isLastChunk: Bool
    let emitTokensAfterFrame: Int?
    let initialTimeIndexOverride: Int?
    let stableThroughSampleCount: Int
    let earliestSafePrefixSampleCount: Int

    var inputSampleCount: Int { chunkEnd - contextStart }
}

struct ASRClosedTokenWindow: Sendable {
    let descriptor: ASRClosedWindowDescriptor
    let tokens: [ChunkProcessor.TokenWindow]
}

enum ASRClosedWindowValidation {
    static func supportsCaching(
        modelVersion: AsrModelVersion?,
        melChunkContext: Bool,
        dualDecodeArbitration: Bool
    ) -> Bool {
        modelVersion == .v3 && !melChunkContext && !dualDecodeArbitration
    }

    /// Reentrancy barrier for the model call inside precomputation. A cache is
    /// stamped with the owner that authorized inference only if that exact
    /// manager/model epoch is still current when inference returns.
    static func ownerAfterInference(
        expected: ASRClosedWindowOwner,
        current: ASRClosedWindowOwner
    ) -> ASRClosedWindowOwner? {
        expected == current ? expected : nil
    }

    static func finalResultMayReuseCache(
        expected: ASRClosedWindowOwner,
        current: ASRClosedWindowOwner
    ) -> Bool {
        expected == current
    }

    static func validatedWindows(
        caches: [ASRClosedWindowCache],
        expectedOwner: ASRClosedWindowOwner,
        languageRawValue: String?,
        finalPlans: [ASRClosedWindowDescriptor],
        finalSamples: [Float]
    ) -> [Int: ASRClosedTokenWindow] {
        let indexCounts = Dictionary(grouping: caches, by: \.descriptor.index).mapValues(\.count)
        var validated: [Int: ASRClosedTokenWindow] = [:]

        for cache in caches {
            let descriptor = cache.descriptor
            guard indexCounts[descriptor.index] == 1,
                cache.owner == expectedOwner,
                cache.languageRawValue == languageRawValue,
                descriptor.index >= 0,
                descriptor.index < finalPlans.count,
                finalPlans[descriptor.index] == descriptor,
                !descriptor.isLastChunk,
                descriptor.contextStart >= 0,
                descriptor.chunkEnd <= finalSamples.count,
                descriptor.inputSampleCount == cache.inputSamples.count,
                cache.tokenIDs.count == cache.timestamps.count,
                cache.tokenIDs.count == cache.confidences.count,
                cache.tokenIDs.count == cache.durations.count,
                samplesMatchExactly(
                    cache.inputSamples,
                    finalSamples[descriptor.contextStart..<descriptor.chunkEnd]
                )
            else {
                continue
            }

            let tokens = cache.tokenIDs.indices.map { index in
                ChunkProcessor.TokenWindow(
                    token: cache.tokenIDs[index],
                    timestamp: cache.timestamps[index],
                    confidence: cache.confidences[index],
                    duration: cache.durations[index]
                )
            }
            validated[descriptor.index] = ASRClosedTokenWindow(
                descriptor: descriptor,
                tokens: tokens
            )
        }
        return validated
    }

    private static func samplesMatchExactly(
        _ cached: [Float],
        _ final: ArraySlice<Float>
    ) -> Bool {
        guard cached.count == final.count else { return false }
        return zip(cached, final).allSatisfy { $0.bitPattern == $1.bitPattern }
    }
}

extension AsrManager {
    /// Returns every exact non-final v3/no-mel/single-decode window that is
    /// already stable and complete in `audioPrefix`.
    ///
    /// Unsupported configurations return an empty list so callers can keep the
    /// ordinary final transcription path without a second policy branch.
    public func closedWindowPlans(
        for audioPrefix: [Float],
        language: Language? = nil
    ) throws -> [ASRClosedWindowPlan] {
        try closedWindowPlanningSnapshot(for: audioPrefix, language: language).plans
    }

    /// Plans only at bounded watermarks. The returned next watermark may be
    /// later than the audio-specific minimum, but is guaranteed not to expose
    /// a descriptor before its complete boundary search and input are fixed.
    public func closedWindowPlanningSnapshot(
        for audioPrefix: [Float],
        language: Language? = nil
    ) throws -> ASRClosedWindowPlanningSnapshot {
        guard isAvailable else { throw ASRError.notInitialized }
        guard supportsClosedWindowCaching else {
            return ASRClosedWindowPlanningSnapshot(plans: [], nextPlanningSampleCount: nil)
        }

        let processor = ChunkProcessor(audioSamples: audioPrefix)
        let descriptors = try processor.closedWindowPlans(
            melChunkContext: melChunkContext,
            modelVersion: modelVersion
        )
        let owner = currentClosedWindowOwner

        let plans: [ASRClosedWindowPlan] = descriptors.compactMap { descriptor in
            guard !descriptor.isLastChunk,
                descriptor.earliestSafePrefixSampleCount <= audioPrefix.count
            else {
                return nil
            }
            return ASRClosedWindowPlan(owner: owner, descriptor: descriptor)
        }
        return ASRClosedWindowPlanningSnapshot(
            plans: plans,
            nextPlanningSampleCount: processor.nextClosedWindowPlanningSampleCount(
                afterExposingThrough: plans.last?.index
            )
        )
    }

    /// Revalidates a plan and copies only its bounded exact model input. This
    /// synchronous actor operation is the privacy boundary before Core ML.
    public func prepareClosedWindow(
        _ plan: ASRClosedWindowPlan,
        from audioPrefix: [Float],
        language: Language? = nil
    ) throws -> ASRPreparedClosedWindow {
        guard isAvailable else { throw ASRError.notInitialized }
        let expectedOwner = currentClosedWindowOwner
        guard supportsClosedWindowCaching,
            plan.owner == expectedOwner,
            plan.descriptor.earliestSafePrefixSampleCount <= audioPrefix.count
        else {
            throw ASRError.processingFailed("closed-window plan is no longer valid")
        }

        let processor = ChunkProcessor(audioSamples: audioPrefix)
        let prefixPlans = try processor.closedWindowPlans(
            melChunkContext: melChunkContext,
            modelVersion: modelVersion
        )
        let descriptor = plan.descriptor
        guard descriptor.index >= 0,
            descriptor.index < prefixPlans.count,
            prefixPlans[descriptor.index] == descriptor,
            !descriptor.isLastChunk,
            descriptor.contextStart >= 0,
            descriptor.chunkEnd <= audioPrefix.count
        else {
            throw ASRError.processingFailed("closed-window plan changed before inference")
        }

        return ASRPreparedClosedWindow(
            owner: expectedOwner,
            language: language,
            descriptor: descriptor,
            inputSamples: Array(audioPrefix[descriptor.contextStart..<descriptor.chunkEnd])
        )
    }

    /// Runs the exact stateless decoder call while retaining only one prepared
    /// input window across the awaited model operation.
    public func precomputeClosedWindow(
        _ prepared: ASRPreparedClosedWindow
    ) async throws -> ASRClosedWindowCache {
        guard isAvailable else { throw ASRError.notInitialized }
        let expectedOwner = prepared.owner
        guard supportsClosedWindowCaching,
            expectedOwner == currentClosedWindowOwner
        else {
            throw ASRError.processingFailed("prepared closed window is no longer valid")
        }

        let descriptor = prepared.descriptor
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        decoderState.reset()
        let output = try await ChunkProcessor.transcribeChunk(
            samples: prepared.inputSamples,
            contextSamples: descriptor.contextSamples,
            chunkStart: descriptor.chunkStartOffset,
            isLastChunk: false,
            using: self,
            decoderState: &decoderState,
            maxModelSamples: ASRConstants.maxModelSamples,
            language: prepared.language,
            emitTokensAfterFrame: descriptor.emitTokensAfterFrame,
            initialTimeIndexOverride: descriptor.initialTimeIndexOverride
        )
        guard output.tokens.count == output.timestamps.count,
            output.tokens.count == output.confidences.count,
            output.tokens.count == output.durations.count
        else {
            throw ASRError.processingFailed("closed-window decoder arrays are misaligned")
        }
        guard supportsClosedWindowCaching,
            let cacheOwner = ASRClosedWindowValidation.ownerAfterInference(
                expected: expectedOwner,
                current: currentClosedWindowOwner
            )
        else {
            throw ASRError.processingFailed("closed-window inference was invalidated")
        }

        return ASRClosedWindowCache(
            owner: cacheOwner,
            languageRawValue: prepared.language?.rawValue,
            descriptor: descriptor,
            inputSamples: prepared.inputSamples,
            tokenIDs: output.tokens,
            timestamps: output.timestamps,
            confidences: output.confidences,
            durations: output.durations
        )
    }

    /// Compatibility convenience. Product streaming code should split prepare
    /// and precompute so the full prefix is released before the await.
    public func precomputeClosedWindow(
        _ plan: ASRClosedWindowPlan,
        from audioPrefix: [Float],
        language: Language? = nil
    ) async throws -> ASRClosedWindowCache {
        let prepared = try prepareClosedWindow(plan, from: audioPrefix, language: language)
        return try await precomputeClosedWindow(prepared)
    }

    /// Transcribes the authoritative final samples while reusing only caches
    /// that still match the current manager epoch, language, final plan, and
    /// exact Float input bits. Every rejected or missing window follows the
    /// ordinary inference path.
    public func transcribe(
        _ audioSamples: [Float],
        decoderState: inout TdtDecoderState,
        language: Language? = nil,
        reusingClosedWindows caches: [ASRClosedWindowCache]
    ) async throws -> ASRResult {
        let shouldEmitProgress = audioSamples.count > ASRConstants.maxModelSamples
        if shouldEmitProgress {
            _ = await progressEmitter.ensureSession()
        }

        do {
            // Cache validation is an optimization boundary. If a future
            // planner/source configuration cannot reconstruct the candidate
            // plan, final recognition must still take the shipping path.
            let expectedOwner = currentClosedWindowOwner
            let validated =
                (try? validatedClosedWindows(
                    caches,
                    finalSamples: audioSamples,
                    language: language
                )) ?? [:]
            let result = try await transcribeWithState(
                audioSamples,
                decoderState: &decoderState,
                language: language,
                precomputedWindows: validated
            )
            if !validated.isEmpty,
                !ASRClosedWindowValidation.finalResultMayReuseCache(
                    expected: expectedOwner,
                    current: currentClosedWindowOwner
                )
            {
                // A reentrant reset/load/cleanup invalidated the accepted map
                // while the long-form call was suspended. Discard the entire
                // candidate result and rerun the shipping path with no cache.
                let fallback = try await transcribeWithState(
                    audioSamples,
                    decoderState: &decoderState,
                    language: language
                )
                if shouldEmitProgress {
                    await progressEmitter.finishSession()
                }
                return fallback
            }
            if shouldEmitProgress {
                await progressEmitter.finishSession()
            }
            return result
        } catch {
            if shouldEmitProgress {
                await progressEmitter.failSession(error)
            }
            throw error
        }
    }

    var supportsClosedWindowCaching: Bool {
        ASRClosedWindowValidation.supportsCaching(
            modelVersion: modelVersion,
            melChunkContext: melChunkContext,
            dualDecodeArbitration: dualDecodeArbitration
        )
    }

    var currentClosedWindowOwner: ASRClosedWindowOwner {
        ASRClosedWindowOwner(
            managerIdentifier: closedWindowCacheIdentifier,
            managerEpoch: closedWindowCacheEpoch
        )
    }

    func validatedClosedWindows(
        _ caches: [ASRClosedWindowCache],
        finalSamples: [Float],
        language: Language?
    ) throws -> [Int: ASRClosedTokenWindow] {
        guard supportsClosedWindowCaching,
            finalSamples.count > ASRConstants.maxModelSamples,
            !caches.isEmpty
        else {
            return [:]
        }

        let processor = ChunkProcessor(audioSamples: finalSamples)
        let finalPlans = try processor.closedWindowPlans(
            melChunkContext: melChunkContext,
            modelVersion: modelVersion
        )
        return ASRClosedWindowValidation.validatedWindows(
            caches: caches,
            expectedOwner: currentClosedWindowOwner,
            languageRawValue: language?.rawValue,
            finalPlans: finalPlans,
            finalSamples: finalSamples
        )
    }
}
