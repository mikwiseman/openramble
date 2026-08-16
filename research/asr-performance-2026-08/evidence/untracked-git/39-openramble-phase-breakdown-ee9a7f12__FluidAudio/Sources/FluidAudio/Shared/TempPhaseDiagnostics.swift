import Foundation

/// TEMP-ONLY diagnostic surface used by the isolated phase benchmark.
/// This file is not part of the shipping repository.
public struct TempASRPhaseSnapshot: Codable, Equatable, Sendable {
    public var transcribeInternalNanoseconds: UInt64 = 0
    public var alignmentAndPaddingNanoseconds: UInt64 = 0
    public var pipelineNanoseconds: UInt64 = 0
    public var preprocessorInputNanoseconds: UInt64 = 0
    public var preprocessorPredictionNanoseconds: UInt64 = 0
    public var encoderInputNanoseconds: UInt64 = 0
    public var encoderPredictionNanoseconds: UInt64 = 0
    public var frontendOutputExtractionNanoseconds: UInt64 = 0
    public var tdtDecodeNanoseconds: UInt64 = 0
    public var cacheReturnNanoseconds: UInt64 = 0
    public var resultProcessingNanoseconds: UInt64 = 0

    public var decoderInvocationNanoseconds: UInt64 = 0
    public var decoderPredictionNanoseconds: UInt64 = 0
    public var jointInvocationNanoseconds: UInt64 = 0
    public var jointPredictionNanoseconds: UInt64 = 0

    public var encoderWindowCount: Int = 0
    public var encoderSequenceLength: Int = 0
    public var actualAudioFrames: Int = 0
    public var effectiveSequenceLength: Int = 0
    public var decoderPredictionCount: Int = 0
    public var jointPredictionCount: Int = 0
    public var decoderCacheHitCount: Int = 0
    public var mainLoopIterationCount: Int = 0
    public var innerLoopIterationCount: Int = 0
    public var finalLoopIterationCount: Int = 0
    public var mainJointDecisionCount: Int = 0
    public var innerJointDecisionCount: Int = 0
    public var finalJointDecisionCount: Int = 0
    public var blankDecisionCount: Int = 0
    public var nonblankDecisionCount: Int = 0
    public var emittedTokenCount: Int = 0
    public var processedTokenCount: Int = 0
    public var durationAdvanceFrameCount: Int = 0
    public var forcedAdvanceCount: Int = 0
    public var maxTokenLimitBreakCount: Int = 0

    public init() {}
}

internal struct TempTDTLoopCounters {
    var encoderSequenceLength: Int = 0
    var actualAudioFrames: Int = 0
    var effectiveSequenceLength: Int = 0
    var decoderCacheHitCount: Int = 0
    var mainLoopIterationCount: Int = 0
    var innerLoopIterationCount: Int = 0
    var finalLoopIterationCount: Int = 0
    var mainJointDecisionCount: Int = 0
    var innerJointDecisionCount: Int = 0
    var finalJointDecisionCount: Int = 0
    var blankDecisionCount: Int = 0
    var nonblankDecisionCount: Int = 0
    var emittedTokenCount: Int = 0
    var processedTokenCount: Int = 0
    var durationAdvanceFrameCount: Int = 0
    var forcedAdvanceCount: Int = 0
    var maxTokenLimitBreakCount: Int = 0
}

internal final class TempASRPhaseRecorder: @unchecked Sendable {
    var snapshot = TempASRPhaseSnapshot()

    @inline(__always)
    func recordDecoderInvocation(totalNanoseconds: UInt64, predictionNanoseconds: UInt64) {
        snapshot.decoderInvocationNanoseconds += totalNanoseconds
        snapshot.decoderPredictionNanoseconds += predictionNanoseconds
        snapshot.decoderPredictionCount += 1
    }

    @inline(__always)
    func recordJointInvocation(totalNanoseconds: UInt64, predictionNanoseconds: UInt64) {
        snapshot.jointInvocationNanoseconds += totalNanoseconds
        snapshot.jointPredictionNanoseconds += predictionNanoseconds
        snapshot.jointPredictionCount += 1
    }

    func recordLoopCounters(_ counters: TempTDTLoopCounters) {
        snapshot.encoderSequenceLength = counters.encoderSequenceLength
        snapshot.actualAudioFrames = counters.actualAudioFrames
        snapshot.effectiveSequenceLength = counters.effectiveSequenceLength
        snapshot.decoderCacheHitCount += counters.decoderCacheHitCount
        snapshot.mainLoopIterationCount += counters.mainLoopIterationCount
        snapshot.innerLoopIterationCount += counters.innerLoopIterationCount
        snapshot.finalLoopIterationCount += counters.finalLoopIterationCount
        snapshot.mainJointDecisionCount += counters.mainJointDecisionCount
        snapshot.innerJointDecisionCount += counters.innerJointDecisionCount
        snapshot.finalJointDecisionCount += counters.finalJointDecisionCount
        snapshot.blankDecisionCount += counters.blankDecisionCount
        snapshot.nonblankDecisionCount += counters.nonblankDecisionCount
        snapshot.emittedTokenCount += counters.emittedTokenCount
        snapshot.processedTokenCount += counters.processedTokenCount
        snapshot.durationAdvanceFrameCount += counters.durationAdvanceFrameCount
        snapshot.forcedAdvanceCount += counters.forcedAdvanceCount
        snapshot.maxTokenLimitBreakCount += counters.maxTokenLimitBreakCount
    }
}

/// A deliberately single-run recorder. The benchmark drives one AsrManager actor
/// in one persistent process, so no production synchronization is introduced.
public enum TempASRPhaseDiagnostics {
    nonisolated(unsafe) private static var activeRecorder: TempASRPhaseRecorder?

    public static func begin() {
        precondition(activeRecorder == nil, "TempASRPhaseDiagnostics.begin called twice")
        activeRecorder = TempASRPhaseRecorder()
    }

    public static func finish() -> TempASRPhaseSnapshot {
        precondition(activeRecorder != nil, "TempASRPhaseDiagnostics.finish without begin")
        let result = activeRecorder!.snapshot
        activeRecorder = nil
        return result
    }

    internal static var recorder: TempASRPhaseRecorder? { activeRecorder }
}

@inline(__always)
internal func tempPhaseNow() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}
