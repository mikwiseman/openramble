import AVFoundation
import DictationCore
import Foundation
import LocalASR
@testable import OpenRamble

/// Records a take by writing a WAV of a tone, so the real file reader runs.
@MainActor
final class FakeRecorder: VoiceRecording {
    var onInterruption: (() -> Void)?
    var isAllowed = true
    var seconds: TimeInterval = 2
    var failure: (any Error)?
    private(set) var url: URL?
    private(set) var discarded = false

    func start(to url: URL) async throws {
        if let failure { throw failure }
        self.url = url
        try writeTone(to: url, seconds: seconds)
    }

    func stop() -> TimeInterval { seconds }

    func discard() {
        discarded = true
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func level() -> Float { 0.5 }
}

func writeTone(to url: URL, seconds: TimeInterval) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let frames = AVAudioFrameCount(seconds * 16_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
        buffer.int16ChannelData![0][index] = Int16(sin(Double(index) * 0.06) * 8_000)
    }
    try file.write(from: buffer)
}

/// An engine that hears whatever the test says it hears.
actor FakeEngine: ASREngineAdapting {
    var heard = "um so this is uh the first take"
    var failure: ASREngineError?
    private(set) var runs = 0

    func say(_ text: String) { heard = text }
    func fail(_ error: ASREngineError?) { failure = error }

    func loadModels(from directory: URL) async throws {}
    func unload() async {}

    func transcribe(samples: [Float]) async throws -> ASRResult {
        runs += 1
        if let failure { throw failure }
        return ASRResult(text: heard, audioDuration: Double(samples.count) / 16_000, processingDuration: 0.01)
    }
}

@MainActor
struct Rig {
    let root: URL
    let store: TakeStore
    let engine: FakeEngine
    let recorder: FakeRecorder
    let dictation: Dictation
    let defaults: UserDefaults

    init(modelReady: Bool = true) async {
        root = URL.temporaryDirectory.appending(path: "rig-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = TakeStore(root: root)
        engine = FakeEngine()
        recorder = FakeRecorder()
        defaults = UserDefaults(suiteName: "rig-\(UUID().uuidString)")!
        dictation = Dictation(
            store: store,
            writer: Writer(transcriber: LocalTranscriber(engine: engine)),
            recorder: recorder,
            liveActivity: nil,
            defaults: defaults
        )
        if modelReady { await dictation.modelBecameReady(at: root) }
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}
