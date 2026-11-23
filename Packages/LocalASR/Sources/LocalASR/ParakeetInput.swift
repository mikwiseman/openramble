import DictationCore
import Foundation

/// What every Parakeet engine takes: the clip's sample rate, the shortest clip
/// its front end accepts, and the one model file in an installed revision.
///
/// Kept apart from both adapters so each compiles without the other. The
/// iPhone has no Metal runtime binary, so `TranscribeCppAdapter` is not built
/// there, and `OreAdapter` still needs these three facts.
public enum ParakeetInput {
    /// Sample rate both engines require. The recorder already produces this, so
    /// nothing resamples on the way in.
    public static let sampleRate = 16_000

    /// The shortest clip the mel front-end will accept without producing NaNs:
    /// 1.25 seconds, the same constant as `MINIMUM_ENGINE_SAMPLES` in
    /// `core/ramble-audio/src/prepare.rs`. The two must move together.
    public static let minimumSamples = sampleRate * 5 / 4

    /// The single GGUF in a prepared revision directory.
    ///
    /// Fails loudly on none and on more than one. A directory holding two
    /// models is an installer bug, and picking one of them arbitrarily would
    /// turn that bug into a mysterious quality complaint months later.
    static func modelFile(in directory: URL) throws -> URL {
        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "gguf" }
        } catch {
            throw ASREngineError.modelsUnavailable("the model directory is unreadable")
        }
        switch candidates.count {
        case 1:
            return candidates[0]
        case 0:
            throw ASREngineError.modelsUnavailable("no model file in the installed revision")
        default:
            throw ASREngineError.modelsUnavailable(
                "the installed revision holds \(candidates.count) model files"
            )
        }
    }
}
