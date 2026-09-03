import AVFoundation
import CoreAudio
import DictationCore
import Foundation

/// The microphone, as a long-running source.
///
/// Its own `AVAudioEngine`, deliberately not `MicrophoneCapture`: that actor
/// is built around a two-second take racing insertion and Escape, and its
/// process-wide gates (one disk writer at a time, two engine starts in
/// flight) exist for that shape. A recording that runs for an hour beside a
/// dictation would trip them and fail the dictation. Two engines on one
/// input device coexist fine — measured: forty start/stop cycles of a second
/// engine, the first never missed a buffer.
///
/// The conversion contract is shared, not copied: `MicrophoneCapture`'s
/// static helpers know that rate and channel equality alone is not a safe
/// zero-copy path, and that rule should exist once.
public final class MicrophoneAudioSource: MeetingAudioSource, @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    /// 128 ms at 16 kHz after conversion; the engine delivers its native rate.
    public static let tapBufferSize: AVAudioFrameCount = 2_048

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private let preferredInputDeviceID: AudioDeviceID?
    private var name: String?

    public init(preferredInputDeviceID: AudioDeviceID? = nil) {
        self.preferredInputDeviceID = preferredInputDeviceID
    }

    public var deviceName: String? {
        lock.lock()
        defer { lock.unlock() }
        return name
    }

    public func start(
        onBlock: @escaping @Sendable (MeetingAudioBlock) -> Void,
        onFailure: @escaping @Sendable (MeetingSourceFailure) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else { throw MeetingSourceFailure.startFailed("already running") }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Point the engine at the chosen microphone before anything reads a
        // format from it; after that the node has negotiated with a device
        // and a change is ignored.
        if let preferredInputDeviceID {
            try Self.select(device: preferredInputDeviceID, on: input)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw MeetingSourceFailure.unavailable("microphone unavailable")
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingSourceFailure.startFailed("couldn't create the recording format")
        }
        let converter: AVAudioConverter?
        do {
            converter = try MicrophoneCapture.converter(from: inputFormat, to: target) {
                AVAudioConverter(from: $0, to: $1)
            }
        } catch {
            throw MeetingSourceFailure.startFailed(String(describing: error))
        }

        // One failure report per run: a converter that rejects every frame
        // would otherwise say so a hundred times a second.
        let reported = UncheckedBox(false)
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { buffer, when in
            let samples: [Float]
            do {
                samples = try MicrophoneCapture.extractSamples(from: buffer, using: converter, target: target)
            } catch {
                if !reported.value {
                    reported.value = true
                    onFailure(.conversionFailed(String(describing: error)))
                }
                return
            }
            guard !samples.isEmpty else { return }
            let host: UInt64? = when.isHostTimeValid
                ? UInt64(AVAudioTime.seconds(forHostTime: when.hostTime) * 1_000_000_000)
                : nil
            onBlock(MeetingAudioBlock(hostNanoseconds: host, samples: samples))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MeetingSourceFailure.startFailed(error.localizedDescription)
        }

        // The device went away or the default moved: the engine has already
        // stopped itself. Say so once; the owner decides whether to start a
        // fresh engine on whatever is default now.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            onFailure(.configurationChanged)
        }

        self.engine = engine
        name = Self.currentDeviceName(of: input)
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private static func select(device id: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else {
            throw MeetingSourceFailure.unavailable("no input unit to choose a microphone on")
        }
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MeetingSourceFailure.unavailable("the chosen microphone didn't accept the recording (\(status))")
        }
    }

    /// The name of the microphone actually in use.
    ///
    /// For the default input the engine reports its own private aggregate
    /// ("CADefaultDeviceAggregate-…"), which names nothing a person owns;
    /// the system default input device behind it is what they would call
    /// the microphone.
    private static func currentDeviceName(of input: AVAudioInputNode) -> String? {
        guard let unit = input.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size
        )
        guard status == noErr, deviceID != 0 else { return nil }
        if let name = name(of: deviceID), !name.hasPrefix("CADefaultDeviceAggregate") {
            return name
        }
        var defaultInput = AudioDeviceID(0)
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &defaultSize, &defaultInput
        )
        guard defaultStatus == noErr, defaultInput != 0 else { return nil }
        return name(of: defaultInput)
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &nameSize, $0)
        }
        guard status == noErr else { return nil }
        return name as String?
    }
}
