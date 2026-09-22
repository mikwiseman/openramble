import DictationAudio
import DictationCore
import Foundation

/// A display offered by ScreenCaptureKit for the next local recording.
public struct ScreenDisplayOption: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let name: String

    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

/// The app-facing seam for the screen recorder. The implementation owns the
/// ScreenCaptureKit stream, camera preview and MP4 writer; AppState owns the
/// recording lifecycle and pairs it with the existing WAV/transcription path.
@MainActor
public protocol ScreenRecordingCapturing: AnyObject {
    var audioSink: any MeetingAudioBlockSink { get }
    var outputURL: URL? { get }
    var displayName: String? { get }

    func prepare() async throws
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func updateCameraEnabled(_ enabled: Bool) async throws
    func updateBubbleScale(_ scale: Double)
    func updateBubblePosition(_ position: NormalizedPoint)
}
