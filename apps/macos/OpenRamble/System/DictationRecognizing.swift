import DictationCore
import Foundation
import LocalASR

/// The recognition lifecycle `AppState` drives.
///
/// Recognition used to run in a separate worker process, reached over a pipe,
/// with generations, exact-PID kills, respawn backoff and a soak suite around
/// it — about 4,300 lines. The isolation it bought was never the problem; the
/// policy attached to it was. A take that ran slowly for an ordinary reason had
/// its worker killed and its loaded model discarded, which made the next take
/// cold and the next failure likelier, and that loop was the instability.
///
/// It now runs in this process, the way the app it is modelled on does. The
/// engine is a 740 MB GGUF on Metal rather than 2.4 GB of Core ML that the OS
/// kept reclaiming, so the process boundary is no longer buying isolation from
/// a memory problem that no longer exists.
///
/// The protocol stays because it is the seam every test drives.
public protocol DictationRecognizing: Sendable {
    var isPrepared: Bool { get async }
    var isBusy: Bool { get async }
    /// Causal changes to inference readiness, for owners that can lose it
    /// without being asked. An in-process recognizer never does.
    func readinessChanges() async -> AsyncStream<Bool>
    func prepare(modelDirectory: URL) async throws
    func transcribe(fileURL: URL, languageHint: String?) async throws -> ASRResult
    func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult
    func warmUpInference() async throws
    func unload() async
    func unloadIfIdle() async -> Bool
}

extension DictationRecognizing {
    public func readinessChanges() async -> AsyncStream<Bool> {
        AsyncStream { $0.finish() }
    }
}

extension LocalTranscriber: DictationRecognizing {}
