import DictationCore

/// Optional native batching. Each result belongs to the input at the same
/// index, including failures and fragments interrupted by a priority yield.
public protocol BatchASREngineAdapting: ASREngineAdapting {
    func transcribe(
        batch: [[Float]],
        timestamps: Bool,
        shouldYield: @escaping @Sendable () -> Bool
    ) async throws -> [Result<ASRResult, ASREngineError>]
}
