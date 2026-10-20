// Where do the ~160 ms before the first live sample go?
//
// The same AVAudioEngine sequence `MicrophoneCapture.startActiveRecording`
// runs, step by step, next to the floor: a bare Core Audio IOProc on the same
// device. Input host times say when the first sample was captured, so no
// sound needs to be played. Numbers only; samples are inspected for being
// non-zero and then dropped.

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

final class FirstBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived: UInt64?
    private var captured: UInt64?
    private var live: UInt64?
    /// Every sample, placed by its own input host time, for the level curve.
    private var chunks: [(host: UInt64, samples: [Float])] = []
    private var rate: Double = 0

    /// `capturedAt` is the input host time of `samples[0]`.
    func offer(capturedAt: UInt64, rate: Double, samples: UnsafeBufferPointer<Float>) {
        let now = mach_absolute_time()
        lock.lock()
        defer { lock.unlock() }
        chunks.append((capturedAt, Array(samples)))
        self.rate = rate
        if arrived == nil {
            arrived = now
            captured = capturedAt
        }
        if live == nil, let index = samples.firstIndex(where: { abs($0) > 1e-6 }) {
            live = host(capturedAt, plus: Double(index) / rate)
        }
    }

    func read() -> (arrived: UInt64?, captured: UInt64?, live: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        return (arrived, captured, live)
    }

    /// Room level in 10 ms windows after `origin`, against the level the
    /// stream settles at 400-550 ms. Nothing captured counts as -200 dB.
    /// No sound is played: the room's own noise is the signal, so a stretch
    /// of digital silence after the first samples shows as a deep hole.
    func levels(after origin: UInt64) -> [Double] {
        lock.lock()
        let chunks = self.chunks
        let rate = self.rate
        lock.unlock()
        guard rate > 0 else { return [] }
        let span = Int(0.550 * rate)
        var timeline = [Float](repeating: 0, count: span)
        var filled = [Bool](repeating: false, count: span)
        for chunk in chunks {
            let start = Int((seconds(from: origin, to: chunk.host) * rate).rounded())
            for (i, x) in chunk.samples.enumerated() where start + i >= 0 && start + i < span {
                timeline[start + i] = x
                filled[start + i] = true
            }
        }
        let window = Int(0.010 * rate)
        func level(_ a: Int, _ b: Int) -> Double {
            let slice = (a..<b).filter { filled[$0] }
            guard !slice.isEmpty else { return -200 }
            let r = (slice.reduce(0.0) { $0 + Double(timeline[$1]) * Double(timeline[$1]) } / Double(slice.count)).squareRoot()
            return r > 0 ? 20 * log10(r) : -200
        }
        let settled = level(Int(0.400 * rate), span)
        return stride(from: 0, to: span - window, by: window).map { level($0, $0 + window) - settled }
    }
}

/// The first window after which the level stays within `threshold` dB.
func settled(_ levels: [Double], within threshold: Double) -> Double {
    guard let last = levels.prefix(40).lastIndex(where: { $0 < -threshold }) else { return 0 }
    return Double(last + 1) * 10
}

func engineStart(device: AudioDeviceID?) throws -> [String: Any] {
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let first = FirstBuffer()
    let probe = device ?? defaultInputDevice() ?? 0
    let runningAtRest = scalar(
        probe, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)
    ) ?? 0
    let called = mach_absolute_time()
    let engine = AVAudioEngine()
    let made = mach_absolute_time()
    let input = engine.inputNode
    if let device { try select(device, on: input.audioUnit) }
    let noded = mach_absolute_time()
    let format = input.outputFormat(forBus: 0)
    let formatted = mach_absolute_time()
    _ = AVAudioConverter(from: format, to: target)
    let converted = mach_absolute_time()
    let rate = format.sampleRate
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
        guard when.isHostTimeValid, let data = buffer.floatChannelData else { return }
        first.offer(
            capturedAt: when.hostTime,
            rate: rate,
            samples: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        )
    }
    let tapped = mach_absolute_time()
    engine.prepare()
    let prepared = mach_absolute_time()
    // Would a prepared, unstarted engine already hold the microphone open?
    let runningBeforeStart = scalar(
        probe, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)
    ) ?? 0
    try engine.start()
    let started = mach_absolute_time()
    Thread.sleep(forTimeInterval: 0.600)
    engine.stop()
    input.removeTap(onBus: 0)
    let seen = first.read()
    func ms(_ t: UInt64?) -> Double { t.map { seconds(from: called, to: $0) * 1000 } ?? -1 }
    return [
        "path": "avaudioengine",
        "engine_init_ms": ms(made),
        "input_node_ms": ms(noded),
        "format_ms": ms(formatted),
        "converter_ms": ms(converted),
        "tap_ms": ms(tapped),
        "prepare_ms": ms(prepared),
        "start_return_ms": ms(started),
        "first_callback_ms": ms(seen.arrived),
        "first_sample_ms": ms(seen.captured),
        "first_live_ms": ms(seen.live),
        "running_at_rest": runningAtRest != 0,
        "running_before_start": runningBeforeStart != 0,
        "level_db": first.levels(after: called),
        "settled_20db_ms": settled(first.levels(after: called), within: 20),
        "settled_10db_ms": settled(first.levels(after: called), within: 10),
    ]
}

func halStart(device: AudioDeviceID) throws -> [String: Any] {
    let busyAtRest = deviceIsRunning(device)
    let called = mach_absolute_time()
    let rate = scalar(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0
    let first = FirstBuffer()
    var proc: AudioDeviceIOProcID?
    let queue = DispatchQueue(label: "onset.hal")
    var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, inputTime, _, _ in
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = list.first, let data = buffer.mData else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        // Interleaved frames: the first channel decides "live" well enough.
        let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        let mono = stride(from: 0, to: count, by: channels).map { samples[$0] }
        mono.withUnsafeBufferPointer {
            first.offer(capturedAt: inputTime.pointee.mHostTime, rate: rate, samples: $0)
        }
    }
    guard status == noErr, let proc else { throw HarnessError("IOProc failed (\(status))") }
    let made = mach_absolute_time()
    status = AudioDeviceStart(device, proc)
    let started = mach_absolute_time()
    guard status == noErr else { throw HarnessError("AudioDeviceStart failed (\(status))") }
    Thread.sleep(forTimeInterval: 0.600)
    AudioDeviceStop(device, proc)
    AudioDeviceDestroyIOProcID(device, proc)
    let seen = first.read()
    func ms(_ t: UInt64?) -> Double { t.map { seconds(from: called, to: $0) * 1000 } ?? -1 }
    return [
        "path": "hal",
        "running_at_rest": busyAtRest,
        "input_node_ms": ms(made),
        "level_db": first.levels(after: called),
        "settled_20db_ms": settled(first.levels(after: called), within: 20),
        "settled_10db_ms": settled(first.levels(after: called), within: 10),
        "start_return_ms": ms(started),
        "first_callback_ms": ms(seen.arrived),
        "first_sample_ms": ms(seen.captured),
        "first_live_ms": ms(seen.live),
    ]
}

/// The previous take's engine, left running with its tap discarding every
/// buffer, while the next take's engine starts. This is what delaying the
/// shutdown of a finished take would look like to the next one.
func lingeringStart(device: AudioDeviceID?, linger: Double) throws -> [String: Any] {
    let keeper = AVAudioEngine()
    let input = keeper.inputNode
    if let device { try select(device, on: input.audioUnit) }
    input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { _, _ in }
    keeper.prepare()
    try keeper.start()
    Thread.sleep(forTimeInterval: linger)
    var row = try engineStart(device: device)
    keeper.stop()
    input.removeTap(onBus: 0)
    row["path"] = "avaudioengine-lingering"
    return row
}

func breakdown(
    device: Device,
    explicit: Bool,
    trials: Int,
    gaps: [Double],
    paths: [String],
    out: FileHandle
) throws {
    var last = host(mach_absolute_time(), plus: -10)
    var index = 0
    for _ in 0..<trials {
        for gap in gaps {
            for path in paths {
                mach_wait_until(host(last, plus: gap))
                var row: [String: Any]
                switch path {
                case "hal": row = try halStart(device: device.id)
                case "avaudioengine-lingering": row = try lingeringStart(device: explicit ? device.id : nil, linger: 0.5)
                case "prebuilt-prepared": row = try prebuiltStart(device: explicit ? device.id : nil, prepareEarly: true, idle: 1.0)
                case "prebuilt-unprepared": row = try prebuiltStart(device: explicit ? device.id : nil, prepareEarly: false, idle: 1.0)
                case "auhal": row = try auhalStart(device: device.id)
                default: row = try engineStart(device: explicit ? device.id : nil)
                }
                last = mach_absolute_time()
                row["kind"] = "breakdown"
                row["path"] = row["path"] ?? path
                row["trial"] = index
                row["gap_s"] = gap
                row["load_1m"] = loadAverage()
                row["device_class"] = device.deviceClass
                try record(row, to: out)
                index += 1
                FileHandle.standardError.write(Data(
                    "\(index) \(path) gap=\(gap) start_return=\(String(format: "%.1f", row["start_return_ms"] as! Double)) first_live=\(String(format: "%.1f", row["first_live_ms"] as! Double))\n".utf8
                ))
            }
        }
    }
}

/// Does this process itself have input running? This is what lights the
/// system's microphone indicator for us.
func thisProcessIsRunningInput() -> Bool? {
    var pid = getpid()
    var where_ = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var object = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &where_,
        UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
    ) == noErr, object != 0 else { return nil }
    return scalar(object, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, UInt32(0)).map { $0 != 0 }
}

func deviceIsRunning(_ device: AudioDeviceID) -> Bool {
    (scalar(device, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0) != 0
}

/// The whole AVAudioEngine graph built and (optionally) prepared before the
/// key-down, idle for `idle` seconds, then only `start()` at the key-down.
/// Records whether the idle graph already holds the microphone open.
func prebuiltStart(device: AudioDeviceID?, prepareEarly: Bool, idle: Double) throws -> [String: Any] {
    let probe = device ?? defaultInputDevice() ?? 0
    let busyAtRest = deviceIsRunning(probe)
    let first = FirstBuffer()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    if let device { try select(device, on: input.audioUnit) }
    let format = input.outputFormat(forBus: 0)
    let rate = format.sampleRate
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
        guard when.isHostTimeValid, let data = buffer.floatChannelData else { return }
        first.offer(
            capturedAt: when.hostTime,
            rate: rate,
            samples: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        )
    }
    if prepareEarly { engine.prepare() }
    Thread.sleep(forTimeInterval: idle)
    let idleDeviceRunning = deviceIsRunning(probe)
    let idleProcessInput = thisProcessIsRunningInput()

    let called = mach_absolute_time()
    if !prepareEarly { engine.prepare() }
    let prepared = mach_absolute_time()
    try engine.start()
    let started = mach_absolute_time()
    let liveProcessInput = thisProcessIsRunningInput()
    Thread.sleep(forTimeInterval: 0.600)
    engine.stop()
    input.removeTap(onBus: 0)
    let seen = first.read()
    func ms(_ t: UInt64?) -> Double { t.map { seconds(from: called, to: $0) * 1000 } ?? -1 }
    return [
        "path": prepareEarly ? "prebuilt-prepared" : "prebuilt-unprepared",
        "running_at_rest": busyAtRest,
        "idle_device_running": idleDeviceRunning,
        "idle_process_input": idleProcessInput ?? false,
        "live_process_input": liveProcessInput ?? false,
        "prepare_ms": ms(prepared),
        "start_return_ms": ms(started),
        "first_callback_ms": ms(seen.arrived),
        "first_sample_ms": ms(seen.captured),
        "first_live_ms": ms(seen.live),
    ]
}

/// A lean input-only AUHAL built entirely after the key-down: no output
/// side, no graph, one input callback.
final class InputUnit: @unchecked Sendable {
    let unit: AudioUnit
    let first = FirstBuffer()
    var rate: Double = 0
    private var storage = [Float](repeating: 0, count: 16_384)

    init(device: AudioDeviceID) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw HarnessError("no HAL output component")
        }
        var made: AudioUnit?
        guard AudioComponentInstanceNew(component, &made) == noErr, let made else {
            throw HarnessError("AUHAL instance failed")
        }
        unit = made
        var on: UInt32 = 1
        var off: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4)
        try select(device, on: unit)
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size)
        rate = deviceFormat.mSampleRate
        var client = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size)
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, time, bus, frames, _ in
                Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags, time, bus, frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
    }

    func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ time: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        let count = min(Int(frames), storage.count)
        return storage.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(count * 4),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)
                )
            )
            let status = AudioUnitRender(unit, flags, time, bus, UInt32(count), &list)
            if status == noErr {
                first.offer(
                    capturedAt: time.pointee.mHostTime,
                    rate: rate,
                    samples: UnsafeBufferPointer(start: buffer.baseAddress, count: count)
                )
            }
            return status
        }
    }
}

func auhalStart(device: AudioDeviceID) throws -> [String: Any] {
    let busyAtRest = deviceIsRunning(device)
    let called = mach_absolute_time()
    let input = try InputUnit(device: device)
    let made = mach_absolute_time()
    AudioUnitInitialize(input.unit)
    let initialized = mach_absolute_time()
    let status = AudioOutputUnitStart(input.unit)
    let started = mach_absolute_time()
    guard status == noErr else { throw HarnessError("AUHAL start failed (\(status))") }
    Thread.sleep(forTimeInterval: 0.600)
    AudioOutputUnitStop(input.unit)
    AudioUnitUninitialize(input.unit)
    AudioComponentInstanceDispose(input.unit)
    let seen = input.first.read()
    func ms(_ t: UInt64?) -> Double { t.map { seconds(from: called, to: $0) * 1000 } ?? -1 }
    return [
        "path": "auhal",
        "running_at_rest": busyAtRest,
        "input_node_ms": ms(made),
        "prepare_ms": ms(initialized),
        "start_return_ms": ms(started),
        "first_callback_ms": ms(seen.arrived),
        "first_sample_ms": ms(seen.captured),
        "first_live_ms": ms(seen.live),
    ]
}
