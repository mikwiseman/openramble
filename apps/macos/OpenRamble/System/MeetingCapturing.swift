import DictationAudio
import DictationCore
import Foundation

/// The recorder as the app sees it.
///
/// The seam that lets a test drive the whole recording flow — start, the
/// live timer, stop, filing — with no microphone, the way `AudioCapturing`
/// does it for dictation. Production is `MeetingCapture`; the test bundle
/// has a fake that answers instantly.
public protocol MeetingCapturing: Sendable {
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws -> MeetingCapture.Summary
    var frameCount: Int { get async }
    var state: MeetingCapture.State { get async }
}

extension MeetingCapture: MeetingCapturing {}
