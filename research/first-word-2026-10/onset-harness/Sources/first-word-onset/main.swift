// First-word onset harness.
//
// A "key-down" here is one call to the shipping `MicrophoneCapture`, the same
// call `DictationController.launchCapture` makes on a hotkey press. A speech
// clip is played through the built-in speakers so that its first word reaches
// the microphone a scripted 0-150 ms after that call. A chirp after the speech
// locates the clip inside the captured 16 kHz take, which tells exactly where
// the first word starts relative to the first live sample the take holds.
//
// Output is numbers only. The captured room audio stays in memory and every
// take file the capture writes is deleted at once.

import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import DictationAudio
import DictationCore
import Foundation

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Host time

let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func ticks(_ seconds: Double) -> Int64 {
    Int64((seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer)).rounded())
}

/// Signed seconds from `earlier` to `later`.
func seconds(from earlier: UInt64, to later: UInt64) -> Double {
    Double(Int64(bitPattern: later &- earlier)) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

func host(_ base: UInt64, plus seconds: Double) -> UInt64 {
    UInt64(bitPattern: Int64(bitPattern: base) &+ ticks(seconds))
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

func waitUntil(_ deadline: UInt64) async {
    let remaining = seconds(from: mach_absolute_time(), to: deadline)
    if remaining > 0.02 {
        try? await Task.sleep(for: .seconds(remaining - 0.01), tolerance: .milliseconds(1))
    }
    mach_wait_until(deadline)
}

// MARK: - Core Audio devices

struct Device {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    let inputs: Int
    let outputs: Int

    var deviceClass: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "bluetooth"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: "continuity"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        default: "other"
        }
    }
}

func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func scalar<T>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ initial: T
) -> T? {
    var where_ = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &value) == noErr ? value : nil
}

func name(of object: AudioObjectID) -> String {
    var where_ = address(kAudioObjectPropertyName)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &value) == noErr,
          let value else { return "" }
    return value.takeRetainedValue() as String
}

func channels(of object: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var where_ = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &where_, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(object, &where_, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func allDevices() -> [Device] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var where_ = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &where_, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &where_, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { id in
        Device(
            id: id,
            name: name(of: id),
            transport: scalar(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0,
            inputs: channels(of: id, kAudioObjectPropertyScopeInput),
            outputs: channels(of: id, kAudioObjectPropertyScopeOutput)
        )
    }
}

func defaultInputDevice() -> AudioDeviceID? {
    scalar(
        AudioObjectID(kAudioObjectSystemObject),
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        AudioDeviceID(0)
    )
}

func select(_ device: AudioDeviceID, on unit: AudioUnit?) throws {
    guard let unit else { throw HarnessError("no audio unit to select a device on") }
    var id = device
    let status = AudioUnitSetProperty(
        unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &id,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else { throw HarnessError("device selection failed (\(status))") }
}

// MARK: - Signals

func chirp(sampleRate: Double) -> [Float] {
    let duration = 0.100
    let f0 = 1000.0
    let f1 = 6000.0
    let n = Int((duration * sampleRate).rounded())
    return (0..<n).map { i in
        let t = Double(i) / sampleRate
        let phase = 2 * Double.pi * (f0 * t + (f1 - f0) * t * t / (2 * duration))
        let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
        return Float(0.7 * window * sin(phase))
    }
}

/// Fourth-order high-pass at 700 Hz. Room rumble and voices below the chirp
/// band otherwise swamp the correlation. Template and take go through the same
/// filter, so its phase delay cancels out of the alignment.
func highPass(_ x: [Float], sampleRate: Double) -> [Float] {
    let w0 = 2 * Double.pi * 700 / sampleRate
    let alpha = sin(w0) / (2 * 0.7071)
    let c = cos(w0)
    let a0 = 1 + alpha
    let b = [(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0]
    let a = [-2 * c / a0, (1 - alpha) / a0]
    var y = x.map(Double.init)
    for _ in 0..<2 {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in y.indices {
            let input = y[i]
            let output = b[0] * input + b[1] * x1 + b[2] * x2 - a[0] * y1 - a[1] * y2
            x2 = x1; x1 = input; y2 = y1; y1 = output
            y[i] = output
        }
    }
    return y.map(Float.init)
}

/// Best normalized cross-correlation of `template` starting in `lower...upper`.
func locate(
    _ template: [Float],
    in signal: [Float],
    lower: Int = 0,
    upper: Int = .max
) -> (index: Int, score: Float)? {
    let m = template.count
    let lo = max(0, lower)
    let hi = min(signal.count - m, upper)
    guard m > 0, hi >= lo else { return nil }
    let count = hi - lo + 1
    var correlation = [Float](repeating: 0, count: count)
    signal.withUnsafeBufferPointer { s in
        vDSP_conv(s.baseAddress! + lo, 1, template, 1, &correlation, 1, vDSP_Length(count), vDSP_Length(m))
    }
    var templateEnergy: Float = 0
    vDSP_svesq(template, 1, &templateEnergy, vDSP_Length(m))
    var prefix = [Double](repeating: 0, count: count + m)
    for j in 0..<(count + m - 1) {
        let x = Double(signal[lo + j])
        prefix[j + 1] = prefix[j] + x * x
    }
    var best: (index: Int, score: Float)?
    for k in 0..<count {
        let energy = prefix[k + m] - prefix[k]
        guard energy > 1e-12 else { continue }
        let score = Float(Double(correlation[k]) / (energy * Double(templateEnergy)).squareRoot())
        if best == nil || score > best!.score { best = (lo + k, score) }
    }
    return best
}

func rms(_ x: ArraySlice<Float>) -> Double {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
}

func resample(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
    guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1),
          let outFormat = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1),
          let converter = AVAudioConverter(from: inFormat, to: outFormat),
          let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
          let output = AVAudioPCMBuffer(
              pcmFormat: outFormat,
              frameCapacity: AVAudioFrameCount(Double(samples.count) * target / source) + 64
          )
    else { throw HarnessError("resampler unavailable") }
    input.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return input
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return buffer
}

// MARK: - Stimulus

/// Speech, a short gap, then the alignment chirp. All positions are known
/// exactly, so finding the chirp in a take places the first word too.
struct Stimulus {
    static let rate = 48_000.0
    static let preRoll = 0.010
    static let gapBeforeChirp = 0.120

    let samples: [Float]
    /// Seconds from the buffer start to the first word's onset.
    let onset: Double
    /// Seconds from the first word's onset to the chirp's first sample.
    let onsetToChirp: Double
    /// Seconds of speech from its onset to its end.
    let speech: Double
    /// The stimulus at 16 kHz, for comparing first-word level.
    let reference16k: [Float]
    var duration: Double { Double(samples.count) / Self.rate }

    init(clipURL: URL) throws {
        let file = try AVAudioFile(forReading: clipURL)
        let format = file.processingFormat
        guard let read = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw HarnessError("clip unreadable")
        }
        try file.read(into: read)
        var clip = Array(UnsafeBufferPointer(start: read.floatChannelData![0], count: Int(read.frameLength)))
        if format.sampleRate != Self.rate {
            clip = try resample(clip, from: format.sampleRate, to: Self.rate)
        }

        // Onset: the first 5 ms window within 45 dB of the loudest one. TTS
        // starts from digital silence, so this is the true start of the word.
        let window = 240
        let levels = stride(from: 0, to: clip.count - window, by: window).map {
            rms(clip[$0..<($0 + window)])
        }
        guard let peak = levels.max(), peak > 0 else { throw HarnessError("clip is silent") }
        let threshold = peak * pow(10, -45.0 / 20)
        guard let first = levels.firstIndex(where: { $0 >= threshold }),
              let last = levels.lastIndex(where: { $0 >= threshold }) else {
            throw HarnessError("clip has no onset")
        }
        let preRollSamples = Int(Self.preRoll * Self.rate)
        let onsetIndex = first * window
        let start = max(0, onsetIndex - preRollSamples)
        var speech = Array(clip[start..<min(clip.count, (last + 1) * window)])
        let gain = 0.5 / Double(speech.map { abs($0) }.max() ?? 1)
        speech = speech.map { Float(Double($0) * gain) }

        let gap = [Float](repeating: 0, count: Int(Self.gapBeforeChirp * Self.rate))
        let tail = [Float](repeating: 0, count: Int(0.060 * Self.rate))
        samples = speech + gap + chirp(sampleRate: Self.rate) + tail
        onset = Double(onsetIndex - start) / Self.rate
        onsetToChirp = Double(speech.count + gap.count - (onsetIndex - start)) / Self.rate
        self.speech = Double(speech.count - (onsetIndex - start)) / Self.rate
        reference16k = try resample(samples, from: Self.rate, to: 16_000)
    }
}

// MARK: - Speakers

/// One running output engine on the built-in speakers, so scheduled playback
/// has a constant, calibrated latency.
final class Speakers {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: Stimulus.rate, channels: 1)!

    init(device: AudioDeviceID) throws {
        engine.attach(player)
        try select(device, on: engine.outputNode.audioUnit)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    func play(_ samples: [Float], at time: UInt64) {
        player.scheduleBuffer(buffer(samples, format: format), at: AVAudioTime(hostTime: time))
    }
}

// MARK: - Calibration

/// Measure scheduled-host-time to arrival-at-the-microphone for the speakers,
/// with the microphone already warm and read through a plain tap whose buffers
/// carry input host times.
func calibrate(
    speakers: Speakers,
    input: AudioDeviceID?,
    shots: Int = 6
) throws -> (latency: [Double], scores: [Float], timestampJitterMs: Double, inputRate: Double) {
    let engine = AVAudioEngine()
    let node = engine.inputNode
    if let input { try select(input, on: node.audioUnit) }
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else { throw HarnessError("calibration microphone unavailable") }
    let lock = NSLock()
    var samples: [Float] = []
    var chunks: [(host: UInt64, start: Int)] = []
    node.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, when in
        guard when.isHostTimeValid, let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        lock.lock()
        chunks.append((when.hostTime, samples.count))
        samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
        lock.unlock()
    }
    engine.prepare()
    try engine.start()
    Thread.sleep(forTimeInterval: 1.0)

    let rate = format.sampleRate
    let playedChirp = chirp(sampleRate: Stimulus.rate)
    var scheduled: [UInt64] = []
    for _ in 0..<shots {
        let at = host(mach_absolute_time(), plus: 0.150)
        speakers.play(playedChirp, at: at)
        scheduled.append(at)
        Thread.sleep(forTimeInterval: 0.400)
    }
    Thread.sleep(forTimeInterval: 0.300)
    engine.stop()
    node.removeTap(onBus: 0)

    lock.lock()
    let signal = samples
    let marks = chunks
    lock.unlock()
    guard let origin = marks.first, signal.contains(where: { $0 != 0 }) else {
        throw HarnessError("calibration heard nothing: microphone permission or a muted input")
    }

    var jitter = 0.0
    for (a, b) in zip(marks, marks.dropFirst()) {
        let expected = Double(b.start - a.start) / rate
        jitter = max(jitter, abs(seconds(from: a.host, to: b.host) - expected) * 1000)
    }

    func hostTime(ofSample index: Int) -> UInt64 {
        let chunk = marks.last(where: { $0.start <= index }) ?? origin
        return host(chunk.host, plus: Double(index - chunk.start) / rate)
    }

    let template = highPass(chirp(sampleRate: rate), sampleRate: rate)
    let filtered = highPass(signal, sampleRate: rate)
    var latency: [Double] = []
    var scores: [Float] = []
    for at in scheduled {
        let expected = Int(seconds(from: origin.host, to: at) * rate)
        guard let hit = locate(
            template,
            in: filtered,
            lower: expected - Int(0.010 * rate),
            upper: expected + Int(0.250 * rate)
        ) else { continue }
        latency.append(seconds(from: at, to: hostTime(ofSample: hit.index)))
        scores.append(hit.score)
    }
    return (latency, scores, jitter, rate)
}

// MARK: - Trials

struct Trial {
    let gap: Double
    let onsetMs: Int
    let playback: Bool
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? loads[0] : -1
}

func record(_ object: [String: Any], to handle: FileHandle) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    handle.write(data)
    handle.write(Data("\n".utf8))
}

func runTrial(
    _ trial: Trial,
    index: Int,
    capture: MicrophoneCapture,
    speakers: Speakers?,
    stimulus: Stimulus,
    outputLatency: Double,
    takeDirectory: URL,
    probedDevice: AudioDeviceID
) async throws -> [String: Any] {
    let template = highPass(chirp(sampleRate: 16_000), sampleRate: 16_000)
    // Another process holding the device open makes this a warm start, not
    // the cold one being measured.
    let busyAtRest = (scalar(
        probedDevice, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)
    ) ?? 0) != 0
    let keyDown = host(mach_absolute_time(), plus: 0.100)
    let onset = Double(trial.onsetMs) / 1000
    let playAt = host(keyDown, plus: onset - outputLatency - stimulus.onset)
    if trial.playback, let speakers { speakers.play(stimulus.samples, at: playAt) }

    await waitUntil(keyDown)
    let called = mach_absolute_time()
    let session = DictationSessionID()
    let url = try await capture.startRecording(session: session, disposition: RecordingDisposition())
    let returned = mach_absolute_time()

    let recordUntil = trial.playback
        ? host(playAt, plus: stimulus.duration + 0.300)
        : host(keyDown, plus: 1.000)
    await waitUntil(recordUntil)
    let freezing = mach_absolute_time()
    let recording = try await capture.freezeRecording(session: session, expectedURL: url)
    let stopped = mach_absolute_time()
    _ = try? await recording.durableURL()
    for file in (try? FileManager.default.contentsOfDirectory(
        at: takeDirectory,
        includingPropertiesForKeys: nil
    )) ?? [] {
        try? FileManager.default.removeItem(at: file)
    }

    let x = recording.samples ?? []
    let firstLive = x.firstIndex(where: { abs($0) > 1e-6 }) ?? x.count
    var row: [String: Any] = [
        "trial": index,
        "gap_s": trial.gap,
        "onset_ms": trial.onsetMs,
        "playback": trial.playback,
        "call_late_ms": seconds(from: keyDown, to: called) * 1000,
        "start_return_ms": seconds(from: called, to: returned) * 1000,
        "first_frame_ms": recording.startupLatency.map(milliseconds) ?? -1,
        "take_ms": Double(x.count) / 16,
        "zero_lead_ms": Double(firstLive) / 16,
        "freeze_ms": seconds(from: freezing, to: stopped) * 1000,
        "load_1m": loadAverage(),
        "device_busy_at_rest": busyAtRest,
    ]
    guard trial.playback else { return row }

    guard let hit = locate(template, in: highPass(x, sampleRate: 16_000)) else {
        row["valid"] = false
        return row
    }
    let onsetIndex = hit.index - Int((stimulus.onsetToChirp * 16_000).rounded())
    let lead = Double(onsetIndex - firstLive) / 16
    row["chirp_score"] = hit.score
    row["valid"] = hit.score >= 0.4
    row["lead_ms"] = lead
    row["lost_ms"] = max(0, -lead)
    row["captured"] = lead >= 0
    // Key-down to the moment whose sound became the first live sample.
    row["dead_ms"] = Double(trial.onsetMs) - lead
    row["first_sample_ms"] = Double(trial.onsetMs) - Double(onsetIndex) / 16

    // Fade-in: the first windows after the first live sample against the rest
    // of the captured speech, each relative to the same stretch of the clean
    // reference. Measured on every take whose first live sample lands inside
    // speech, which is most of them, and only where the reference is loud
    // enough for a ratio to mean something.
    do {
        let ref = stimulus.reference16k
        let shift = Int((stimulus.onset * 16_000).rounded()) - onsetIndex
        let speechEnd = onsetIndex + Int(stimulus.speech * 16_000)
        let peak = ref.map { abs($0) }.max() ?? 1
        func gain(_ a: Int, _ b: Int) -> Double? {
            guard a >= 0, b <= x.count, a + shift >= 0, b + shift <= ref.count, b > a else { return nil }
            let r = rms(ref[(a + shift)..<(b + shift)])
            guard r > Double(peak) * 0.01 else { return nil }
            return rms(x[a..<b]) / r
        }
        if let rest = gain(firstLive + 3_200, speechEnd) {
            for (from, to) in [(0, 25), (25, 50), (50, 100), (100, 200)] {
                if let g = gain(firstLive + from * 16, firstLive + to * 16), g > 0 {
                    row["fade_db_\(from)_\(to)"] = 20 * log10(g / rest)
                }
            }
        }
    }

    // Each early window of the word against the whole utterance, both relative
    // to the clean reference. A device that fades in shows up as a deficit in
    // the windows nearest the first live sample.
    let refOnset = Int((stimulus.onset * 16_000).rounded())
    let whole = Int(stimulus.speech * 16_000)
    let ref = stimulus.reference16k
    if onsetIndex >= 0, onsetIndex + whole <= x.count, refOnset + whole <= ref.count {
        let wholeGain = rms(x[onsetIndex..<(onsetIndex + whole)]) / rms(ref[refOnset..<(refOnset + whole)])
        for (from, to) in [(0, 50), (50, 100), (100, 150), (150, 300), (0, 150)] {
            let a = from * 16, b = to * 16
            let gain = rms(x[(onsetIndex + a)..<(onsetIndex + b)]) / rms(ref[(refOnset + a)..<(refOnset + b)])
            if gain > 0, wholeGain > 0 {
                row["level_db_\(from)_\(to)"] = 20 * log10(gain / wholeGain)
            }
        }
    }
    return row
}

// MARK: - Main

struct Options {
    var list = false
    var device: String?
    var clip: String?
    var out: String?
    var reps = 5
    var onsets = [0, 25, 50, 75, 100, 125, 150, 500]
    var gaps = [3.0, 0.5]
    var idleTrials = 8
    var idleGap = 15.0
    var silentTrials = 10
    var breakdownTrials = 0
    var profileTrials = 0
    var roomTrials = 0
    var paths = ["avaudioengine", "hal", "avaudioengine-lingering", "prebuilt-prepared", "prebuilt-unprepared", "auhal"]
    var seed: UInt64 = 20_261_020

    init(_ arguments: [String]) throws {
        var it = arguments.dropFirst().makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw HarnessError("\(flag) needs a value") }
            return v
        }
        while let flag = it.next() {
            switch flag {
            case "--list": list = true
            case "--device": device = try value(flag)
            case "--clip": clip = try value(flag)
            case "--out": out = try value(flag)
            case "--reps": reps = Int(try value(flag)) ?? reps
            case "--onsets": onsets = try value(flag).split(separator: ",").compactMap { Int($0) }
            case "--gaps": gaps = try value(flag).split(separator: ",").compactMap { Double($0) }
            case "--idle-trials": idleTrials = Int(try value(flag)) ?? idleTrials
            case "--idle-gap": idleGap = Double(try value(flag)) ?? idleGap
            case "--silent-trials": silentTrials = Int(try value(flag)) ?? silentTrials
            case "--seed": seed = UInt64(try value(flag)) ?? seed
            case "--breakdown": breakdownTrials = Int(try value(flag)) ?? 0
            case "--profile": profileTrials = Int(try value(flag)) ?? 0
            case "--room": roomTrials = Int(try value(flag)) ?? 0
            case "--paths": paths = try value(flag).split(separator: ",").map(String.init)
            default: throw HarnessError("unknown flag \(flag)")
            }
        }
    }
}

func main() async throws {
    let options = try Options(CommandLine.arguments)
    let devices = allDevices()
    if options.list {
        for d in devices {
            print("\(d.id)\t\(d.deviceClass)\tin=\(d.inputs)\tout=\(d.outputs)\t\(d.name)")
        }
        return
    }
    guard let outPath = options.out else {
        throw HarnessError("usage: first-word-onset --clip clip.wav --out run.jsonl [--device name]")
    }

    // The device under test. Without --device the capture gets nil, exactly
    // like the app when nobody has picked a microphone.
    let explicit: Device?
    if let wanted = options.device {
        guard let match = devices.first(where: {
            $0.inputs > 0 && $0.name.localizedCaseInsensitiveContains(wanted)
        }) else { throw HarnessError("no input device matches \(wanted)") }
        explicit = match
    } else {
        explicit = nil
    }
    guard let tested = explicit ?? defaultInputDevice().flatMap({ id in devices.first { $0.id == id } }) else {
        throw HarnessError("no input device")
    }
    let handle: FileHandle = try {
        FileManager.default.createFile(atPath: outPath, contents: nil)
        return try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
    }()
    defer { try? handle.close() }

    if options.roomTrials > 0 {
        let takeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "first-word-room-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: takeDirectory) }
        let capture = MicrophoneCapture(directory: takeDirectory, preferredInputDeviceID: explicit?.id)
        var last = host(mach_absolute_time(), plus: -10)
        var index = 0
        for _ in 0..<options.roomTrials {
            for gap in options.gaps {
                await waitUntil(host(last, plus: gap))
                var row = try await runRoom(
                    gap: gap, index: index, capture: capture,
                    takeDirectory: takeDirectory, probedDevice: tested.id
                )
                last = mach_absolute_time()
                row["device_class"] = tested.deviceClass
                try record(row, to: handle)
                index += 1
                FileHandle.standardError.write(Data(
                    "\(index) gap=\(gap) start_return=\(String(format: "%.1f", row["start_return_ms"] as! Double)) settled_20db=\(row["settled_20db_ms"]!)\n".utf8
                ))
            }
        }
        return
    }

    if options.breakdownTrials > 0 {
        try breakdown(
            device: tested,
            explicit: explicit != nil,
            trials: options.breakdownTrials,
            gaps: options.gaps,
            paths: options.paths,
            out: handle
        )
        return
    }

    guard let speakerDevice = devices.first(where: {
        $0.transport == kAudioDeviceTransportTypeBuiltIn && $0.outputs > 0
    }) else { throw HarnessError("no built-in speakers") }

    let speakers = try Speakers(device: speakerDevice.id)
    try speakers.start()

    let calibration = try calibrate(speakers: speakers, input: explicit?.id)
    let good = zip(calibration.latency, calibration.scores).filter { $0.1 >= 0.4 }.map(\.0).sorted()
    guard good.count >= 3 else {
        throw HarnessError("calibration found the chirp \(good.count) times; raise the volume or move the mic")
    }
    let outputLatency = good[good.count / 2]

    if options.profileTrials > 0 {
        try record([
            "kind": "run",
            "device_class": tested.deviceClass,
            "output_latency_ms": outputLatency * 1000,
            "calibration_ms": calibration.latency.map { $0 * 1000 },
            "timestamp_jitter_ms": calibration.timestampJitterMs,
            "input_rate": calibration.inputRate,
            "mode": "profile",
        ], to: handle)
        let takeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "first-word-profile-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: takeDirectory) }
        let capture = MicrophoneCapture(directory: takeDirectory, preferredInputDeviceID: explicit?.id)
        let noise = NoiseStimulus(seed: options.seed)
        var last = host(mach_absolute_time(), plus: -10)
        var index = 0
        for _ in 0..<options.profileTrials {
            for gap in options.gaps {
                await waitUntil(host(last, plus: gap))
                var row = try await runProfile(
                    gap: gap, index: index, capture: capture, speakers: speakers, stimulus: noise,
                    outputLatency: outputLatency, takeDirectory: takeDirectory, probedDevice: tested.id
                )
                last = mach_absolute_time()
                row["device_class"] = tested.deviceClass
                try record(row, to: handle)
                index += 1
                FileHandle.standardError.write(Data(
                    "\(index) gap=\(gap) settled_3db=\(row["settled_3db_ms"] ?? "-") first_live=\(row["first_live_ms"] ?? "-")\n".utf8
                ))
            }
        }
        speakers.stop()
        return
    }
    guard let clipPath = options.clip else { throw HarnessError("--clip is required") }
    let stimulus = try Stimulus(clipURL: URL(fileURLWithPath: clipPath))

    let inputLatencyFrames = scalar(tested.id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput, UInt32(0)) ?? 0
    let inputSafetyFrames = scalar(tested.id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, UInt32(0)) ?? 0
    let inputBufferFrames = scalar(tested.id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeInput, UInt32(0)) ?? 0
    try record([
        "kind": "run",
        "device_class": tested.deviceClass,
        "explicit_device": explicit != nil,
        "input_rate": calibration.inputRate,
        "input_latency_frames": inputLatencyFrames,
        "input_safety_frames": inputSafetyFrames,
        "input_buffer_frames": inputBufferFrames,
        "output_latency_ms": outputLatency * 1000,
        "calibration_ms": calibration.latency.map { $0 * 1000 },
        "calibration_scores": calibration.scores,
        "timestamp_jitter_ms": calibration.timestampJitterMs,
        "stimulus_onset_to_chirp_ms": stimulus.onsetToChirp * 1000,
        "stimulus_speech_ms": stimulus.speech * 1000,
        "seed": options.seed,
    ], to: handle)
    FileHandle.standardError.write(Data(
        "class=\(tested.deviceClass) output_latency_ms=\(String(format: "%.2f", outputLatency * 1000)) calibration=\(calibration.latency.map { String(format: "%.2f", $0 * 1000) })\n".utf8
    ))

    var trials: [Trial] = []
    for gap in options.gaps {
        for onset in options.onsets {
            for _ in 0..<options.reps { trials.append(Trial(gap: gap, onsetMs: onset, playback: true)) }
        }
    }
    let primary = options.onsets.filter { $0 <= 150 }
    for i in 0..<options.idleTrials {
        trials.append(Trial(gap: options.idleGap, onsetMs: primary[i % primary.count], playback: true))
    }
    var rng = SplitMix64(state: options.seed)
    trials.shuffle(using: &rng)
    for _ in 0..<options.silentTrials { trials.append(Trial(gap: 3.0, onsetMs: 0, playback: false)) }

    let takeDirectory = FileManager.default.temporaryDirectory
        .appending(path: "first-word-onset-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: takeDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: takeDirectory) }
    let capture = MicrophoneCapture(directory: takeDirectory, preferredInputDeviceID: explicit?.id)

    var lastStop = host(mach_absolute_time(), plus: -10)
    var speakersRunning = true
    for (index, trial) in trials.enumerated() {
        if !trial.playback, speakersRunning {
            // Control: the speakers' own I/O must not be what warms the mic.
            speakers.stop()
            speakersRunning = false
        }
        await waitUntil(host(lastStop, plus: trial.gap))
        var row = try await runTrial(
            trial,
            index: index,
            capture: capture,
            speakers: speakersRunning ? speakers : nil,
            stimulus: stimulus,
            outputLatency: outputLatency,
            takeDirectory: takeDirectory,
            probedDevice: tested.id
        )
        lastStop = mach_absolute_time()
        row["kind"] = "trial"
        row["device_class"] = tested.deviceClass
        try record(row, to: handle)
        let lead = (row["lead_ms"] as? Double).map { String(format: "%.1f", $0) } ?? "-"
        FileHandle.standardError.write(Data(
            "\(index + 1)/\(trials.count) gap=\(trial.gap) onset=\(trial.onsetMs) lead_ms=\(lead) first_frame_ms=\(String(format: "%.1f", row["first_frame_ms"] as? Double ?? -1))\n".utf8
        ))
    }
    if speakersRunning { speakers.stop() }
}

do {
    try await main()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
