import AVFoundation
import Foundation
import LocalASR

/// Something that records a take into a file.
@MainActor
protocol VoiceRecording: AnyObject {
    /// Starts writing 16 kHz mono PCM to `url`.
    func start(to url: URL) async throws
    /// Stops and returns the seconds recorded. The file is complete when this returns.
    func stop() -> TimeInterval
    /// Stops and deletes the file.
    func discard()
    /// How loud the voice is right now, 0 to 1.
    func level() -> Float
    /// Called when the system takes the microphone away (a call, Siri).
    var onInterruption: (() -> Void)? { get set }
    /// Whether recording can start without asking the person first, which
    /// an intent running in the background cannot do.
    var isAllowed: Bool { get }
}

enum RecordingError: Error, Equatable {
    case microphoneDenied
    case couldNotStart(String)
}

/// The iPhone's microphone, through `AVAudioRecorder`.
///
/// The recorder writes the file as it goes, so a take survives the app being
/// ended mid-sentence. It records straight at the rate the engine needs
/// (16 kHz mono, 16-bit), so nothing is resampled afterwards.
@MainActor
final class MicrophoneRecorder: NSObject, VoiceRecording {
    var onInterruption: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var interruptionObserver: (any NSObjectProtocol)?

    var isAllowed: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    func start(to url: URL) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw RecordingError.microphoneDenied
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            throw RecordingError.couldNotStart(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw RecordingError.couldNotStart(error.localizedDescription)
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecordingError.couldNotStart("the microphone did not start")
        }
        self.recorder = recorder
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) == .began
            guard began else { return }
            MainActor.assumeIsolated { self?.onInterruption?() }
        }
    }

    func stop() -> TimeInterval {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        finish()
        return duration
    }

    func discard() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        finish()
    }

    func level() -> Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return Self.normalized(decibels: recorder.averagePower(forChannel: 0))
    }

    /// Speech sits between about -50 dB (a whisper across the room) and 0 dB;
    /// mapped so ordinary talking fills most of the range.
    nonisolated static func normalized(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        let floor: Float = -50
        return max(0, min(1, (decibels - floor) / -floor))
    }

    private func finish() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

#if DEBUG
/// Plays a real recording in place of the microphone, for the Simulator and
/// for screenshots: launch with `-replay /path/to/speech.wav`. The take's
/// audio is that file, so the words that appear are real recognition of real
/// speech. Not compiled into release builds.
@MainActor
final class ReplayRecorder: VoiceRecording {
    var onInterruption: (() -> Void)?
    let isAllowed = true
    private let source: URL
    private var envelope: [Float] = []
    private var started: Date?
    private var destination: URL?

    init(source: URL) {
        self.source = source
    }

    static func fromLaunchArguments() -> ReplayRecorder? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-replay"), arguments.indices.contains(index + 1) else { return nil }
        return ReplayRecorder(source: URL(filePath: arguments[index + 1]))
    }

    func start(to url: URL) async throws {
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            throw RecordingError.couldNotStart(error.localizedDescription)
        }
        destination = url
        started = .now
        let samples = (try? await Task.detached { try AudioFileReader().samples(from: url) }.value) ?? []
        // Loudness every 50 ms, from the file's own samples.
        envelope = stride(from: 0, to: samples.count, by: 800).map { start in
            let slice = samples[start..<min(start + 800, samples.count)]
            let rms = (slice.reduce(0) { $0 + $1 * $1 } / Float(max(slice.count, 1))).squareRoot()
            return MicrophoneRecorder.normalized(decibels: 20 * log10(max(rms, 1e-6)))
        }
    }

    func stop() -> TimeInterval {
        defer { started = nil }
        return Double(envelope.count) * 0.05
    }

    func discard() {
        if let destination { try? FileManager.default.removeItem(at: destination) }
        started = nil
    }

    func level() -> Float {
        guard let started, !envelope.isEmpty else { return 0 }
        let index = Int(Date.now.timeIntervalSince(started) / 0.05)
        return index < envelope.count ? envelope[index] : 0
    }
}
#endif
