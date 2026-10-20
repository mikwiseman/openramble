// When does the take hear at full level?
//
// "First non-zero sample" says when the device started delivering, not when
// what it delivers is the room at its true level. Steady noise plays from
// 300 ms before the key-down until well after it, then a chirp places the
// take on the key-down timeline. The level of each 10 ms window, against the
// level the same take settles at, shows how the start actually sounds.

import AVFoundation
import DictationAudio
import DictationCore
import Foundation

struct NoiseStimulus {
    static let lead = 0.300
    static let noise = 1.300
    static let gapBeforeChirp = 0.060

    let samples: [Float]
    /// Seconds from the buffer start to the key-down.
    let keyDown: Double
    /// Seconds from the key-down to the chirp's first sample.
    let keyDownToChirp: Double
    var duration: Double { Double(samples.count) / Stimulus.rate }

    init(seed: UInt64) {
        var rng = SplitMix64(state: seed)
        let count = Int(Self.noise * Stimulus.rate)
        var noise = (0..<count).map { _ in Float(Double(rng.next() >> 11) / Double(1 << 53) * 2 - 1) }
        // Band-limit the hiss to where a voice and the speakers live.
        noise = highPass(noise, sampleRate: Stimulus.rate)
        var smoothed = noise
        for i in 1..<smoothed.count { smoothed[i] = 0.35 * noise[i] + 0.65 * smoothed[i - 1] }
        let peak = smoothed.map(abs).max() ?? 1
        let ramp = Int(0.005 * Stimulus.rate)
        noise = smoothed.enumerated().map { i, x in
            let edge = min(1, Float(min(i, count - 1 - i)) / Float(ramp))
            return 0.6 * x / peak * edge
        }
        let gap = [Float](repeating: 0, count: Int(Self.gapBeforeChirp * Stimulus.rate))
        let tail = [Float](repeating: 0, count: Int(0.060 * Stimulus.rate))
        samples = noise + gap + chirp(sampleRate: Stimulus.rate) + tail
        keyDown = Self.lead
        keyDownToChirp = Self.noise + Self.gapBeforeChirp - Self.lead
    }
}

func runProfile(
    gap: Double,
    index: Int,
    capture: MicrophoneCapture,
    speakers: Speakers,
    stimulus: NoiseStimulus,
    outputLatency: Double,
    takeDirectory: URL,
    probedDevice: AudioDeviceID
) async throws -> [String: Any] {
    let template = highPass(chirp(sampleRate: 16_000), sampleRate: 16_000)
    let busyAtRest = deviceIsRunning(probedDevice)
    let keyDown = host(mach_absolute_time(), plus: 0.400)
    let playAt = host(keyDown, plus: -stimulus.keyDown - outputLatency)
    speakers.play(stimulus.samples, at: playAt)

    await waitUntil(keyDown)
    let called = mach_absolute_time()
    let session = DictationSessionID()
    let url = try await capture.startRecording(session: session, disposition: RecordingDisposition())
    let returned = mach_absolute_time()
    await waitUntil(host(playAt, plus: stimulus.duration + 0.200))
    let recording = try await capture.freezeRecording(session: session, expectedURL: url)
    _ = try? await recording.durableURL()
    for file in (try? FileManager.default.contentsOfDirectory(at: takeDirectory, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: file)
    }

    let x = recording.samples ?? []
    var row: [String: Any] = [
        "kind": "profile",
        "trial": index,
        "gap_s": gap,
        "device_busy_at_rest": busyAtRest,
        "call_late_ms": seconds(from: keyDown, to: called) * 1000,
        "start_return_ms": seconds(from: called, to: returned) * 1000,
        "first_frame_ms": recording.startupLatency.map(milliseconds) ?? -1,
        "load_1m": loadAverage(),
    ]
    guard let hit = locate(template, in: highPass(x, sampleRate: 16_000)), hit.score >= 0.4 else {
        row["valid"] = false
        return row
    }
    // Index in the take of the moment of the key-down (negative: before it began).
    let keyDownIndex = hit.index - Int((stimulus.keyDownToChirp * 16_000).rounded())
    let firstLive = x.firstIndex(where: { abs($0) > 1e-6 }) ?? x.count
    func level(_ fromMs: Int, _ toMs: Int) -> Double? {
        let a = keyDownIndex + fromMs * 16, b = keyDownIndex + toMs * 16
        guard a >= 0, b <= x.count else { return nil }
        let r = rms(x[a..<b])
        return r > 0 ? 20 * log10(r) : -200
    }
    guard let steady = level(600, 900) else {
        row["valid"] = false
        return row
    }
    // 10 ms windows from the key-down; before the take began counts as silence.
    let windows: [Double] = stride(from: 0, to: 500, by: 10).map { t in
        (level(t, t + 10) ?? -200) - steady
    }
    func settled(_ threshold: Double) -> Double {
        // The first window after which every window stays within `threshold`.
        guard let last = windows.lastIndex(where: { $0 < -threshold }) else { return 0 }
        return Double(last + 1) * 10
    }
    row["valid"] = true
    row["chirp_score"] = hit.score
    row["first_live_ms"] = Double(firstLive - keyDownIndex) / 16
    row["level_db"] = windows
    row["settled_20db_ms"] = settled(20)
    row["settled_10db_ms"] = settled(10)
    row["settled_3db_ms"] = settled(3)
    return row
}

/// The same question with no sound at all: one second of the room through
/// `MicrophoneCapture`, its level in 10 ms windows from the take's first
/// sample. The take's first sample was captured when `startRecording`
/// returned, within ~2 ms on the engine path (research/first-word-2026-10),
/// so the curve is placed on the key-down timeline by that offset.
func runRoom(
    gap: Double,
    index: Int,
    capture: MicrophoneCapture,
    takeDirectory: URL,
    probedDevice: AudioDeviceID
) async throws -> [String: Any] {
    let busyAtRest = deviceIsRunning(probedDevice)
    let called = mach_absolute_time()
    let session = DictationSessionID()
    let url = try await capture.startRecording(session: session, disposition: RecordingDisposition())
    let returned = mach_absolute_time()
    await waitUntil(host(called, plus: 1.000))
    let recording = try await capture.freezeRecording(session: session, expectedURL: url)
    _ = try? await recording.durableURL()
    for file in (try? FileManager.default.contentsOfDirectory(at: takeDirectory, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: file)
    }
    let x = recording.samples ?? []
    func level(_ a: Int, _ b: Int) -> Double {
        guard a >= 0, b <= x.count, b > a else { return -200 }
        let r = rms(x[a..<b])
        return r > 0 ? 20 * log10(r) : -200
    }
    let settledLevel = level(6_400, 9_600)
    let windows = stride(from: 0, to: 8_000, by: 160).map { level($0, $0 + 160) - settledLevel }
    let startReturn = seconds(from: called, to: returned) * 1000
    return [
        "kind": "room",
        "trial": index,
        "gap_s": gap,
        "device_busy_at_rest": busyAtRest,
        "start_return_ms": startReturn,
        "first_frame_ms": recording.startupLatency.map(milliseconds) ?? -1,
        "level_db_from_first_sample": windows,
        "settled_20db_after_first_sample_ms": settled(windows, within: 20),
        "settled_10db_after_first_sample_ms": settled(windows, within: 10),
        "settled_20db_ms": startReturn + settled(windows, within: 20),
        "load_1m": loadAverage(),
    ]
}
