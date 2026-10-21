import AVFoundation
import CoreAudio
import Darwin
import DictationCore
import Foundation

/// Whether another process has hogged the input device.
///
/// Core Audio hog mode is the only true exclusive lock. A conferencing app
/// that uses Voice Processing I/O does not set it: the microphone stays
/// shared, as three channels on a Mac's built-in microphones. This is the
/// case we can name before we start.
enum MicrophoneHogState: Equatable {
    case free
    case thisProcess
    case otherProcess(pid_t)

    static func interpret(hogPID: pid_t, selfPID: pid_t) -> MicrophoneHogState {
        guard hogPID >= 0 else { return .free }
        return hogPID == selfPID ? .thisProcess : .otherProcess(hogPID)
    }
}

/// The microphone, as a long-running source.
///
/// A HAL I/O proc on the input device, not `AVAudioEngine.inputNode`. The
/// engine tap starts without error and delivers zeros when the headset is in
/// HFP. Adding an I/O proc is the documented way a second client shares an
/// input. While a conferencing app holds Voice Processing I/O, a Mac's
/// built-in microphones are three channels, recorded through the first like
/// every other input. (The silence once blamed on the engine there came from
/// a converter that mapped none of the three.) Hog mode is the one case that
/// still refuses, and that refusal is an error rather than an hour of silence.
///
/// `MicrophoneCapture` is not reused: that actor is built around a two-second
/// take racing insertion and Escape, and its process-wide gates would fail a
/// dictation that overlapped a long recording.
public final class MicrophoneAudioSource: MeetingAudioSource, @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var preferredInputDeviceID: AudioDeviceID?
    private var name: String?
    private var session: Session = .idle
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?
    private var aliveDevice: AudioDeviceID?
    private let ioQueue = DispatchQueue(label: "is.waiwai.dictation.meeting-microphone")

    private enum Session {
        case idle
        case hal(device: AudioDeviceID, procID: AudioDeviceIOProcID)
        case engine(AVAudioEngine, observer: NSObjectProtocol)
    }

    public init(preferredInputDeviceID: AudioDeviceID? = nil) {
        self.preferredInputDeviceID = preferredInputDeviceID
    }

    public var deviceName: String? {
        lock.lock()
        defer { lock.unlock() }
        return name
    }

    public func prepareForRecovery() {
        lock.lock()
        preferredInputDeviceID = nil
        lock.unlock()
    }

    public func start(
        onBlock: @escaping @Sendable (MeetingAudioBlock) -> Void,
        onFailure: @escaping @Sendable (MeetingSourceFailure) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard case .idle = session else { throw MeetingSourceFailure.startFailed("already running") }

        let preferred = preferredInputDeviceID
        do {
            try startHAL(preferred: preferred, onBlock: onBlock, onFailure: onFailure)
        } catch let failure as MeetingSourceFailure {
            if case .startFailed(let message) = failure, message.contains("exclusive access") {
                throw failure
            }
            // HAL refused for some other reason. The engine still hears some
            // devices the I/O proc does not; a hogged one is not among them,
            // which is why exclusive access does not fall here.
            try startEngine(preferred: preferred, onBlock: onBlock, onFailure: onFailure)
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        tearDownListeners()
        switch session {
        case .idle:
            break
        case let .hal(device, procID):
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        case let .engine(engine, observer):
            NotificationCenter.default.removeObserver(observer)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        session = .idle
    }

    // MARK: - HAL

    private func startHAL(
        preferred: AudioDeviceID?,
        onBlock: @escaping @Sendable (MeetingAudioBlock) -> Void,
        onFailure: @escaping @Sendable (MeetingSourceFailure) -> Void
    ) throws {
        guard let device = preferred ?? Self.defaultInputDevice(), device != 0 else {
            throw MeetingSourceFailure.unavailable("microphone unavailable")
        }
        if case .otherProcess = MicrophoneHogState.interpret(
            hogPID: Self.hogPID(of: device) ?? -1,
            selfPID: getpid()
        ) {
            throw MeetingSourceFailure.startFailed("another app has exclusive access to the microphone")
        }

        let native = Self.nativeFormat(of: device)
        guard let sourceFormat = CaptureInputs.format(of: native.asbd),
              sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0,
              let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
              )
        else {
            throw MeetingSourceFailure.startFailed("couldn't describe the microphone's audio format")
        }
        let converter: AVAudioConverter?
        do {
            converter = try MicrophoneCapture.converter(from: sourceFormat, to: target) {
                AVAudioConverter(from: $0, to: $1)
            }
        } catch {
            throw MeetingSourceFailure.startFailed(String(describing: error))
        }

        let reported = UncheckedBox(false)
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { _, inputData, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                bufferListNoCopy: inputData,
                deallocator: nil
            ), buffer.frameLength > 0 else { return }
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
            let stamp = inputTime.pointee
            let host: UInt64? = stamp.mFlags.contains(.hostTimeValid)
                ? UInt64(AVAudioTime.seconds(forHostTime: stamp.mHostTime) * 1_000_000_000)
                : nil
            onBlock(MeetingAudioBlock(hostNanoseconds: host, samples: samples))
        }
        guard status == noErr, let procID else {
            throw MeetingSourceFailure.startFailed("the microphone could not be read (\(status))")
        }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            throw MeetingSourceFailure.startFailed("the microphone could not be started (\(status))")
        }

        session = .hal(device: device, procID: procID)
        name = Self.name(of: device)
        listenForChanges(device: device, pinned: preferred != nil, onFailure: onFailure)
    }

    // MARK: - Engine fallback

    private func startEngine(
        preferred: AudioDeviceID?,
        onBlock: @escaping @Sendable (MeetingAudioBlock) -> Void,
        onFailure: @escaping @Sendable (MeetingSourceFailure) -> Void
    ) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let preferred {
            try Self.select(device: preferred, on: input)
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

        let reported = UncheckedBox(false)
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { buffer, when in
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

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            onFailure(.configurationChanged)
        }
        session = .engine(engine, observer: observer)
        name = Self.currentDeviceName(of: input)
    }

    // MARK: - Route changes

    private func listenForChanges(
        device: AudioDeviceID,
        pinned: Bool,
        onFailure: @escaping @Sendable (MeetingSourceFailure) -> Void
    ) {
        if !pinned {
            var address = Self.defaultInputAddress
            let block: AudioObjectPropertyListenerBlock = { _, _ in onFailure(.configurationChanged) }
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, block
            )
            defaultInputListener = block
        }
        var aliveAddress = Self.deviceAliveAddress
        let alive: AudioObjectPropertyListenerBlock = { _, _ in onFailure(.configurationChanged) }
        AudioObjectAddPropertyListenerBlock(device, &aliveAddress, nil, alive)
        deviceAliveListener = alive
        aliveDevice = device
    }

    private func tearDownListeners() {
        if let defaultInputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, defaultInputListener
            )
        }
        if let deviceAliveListener, let aliveDevice {
            var address = Self.deviceAliveAddress
            AudioObjectRemovePropertyListenerBlock(aliveDevice, &address, nil, deviceAliveListener)
        }
        defaultInputListener = nil
        deviceAliveListener = nil
        aliveDevice = nil
    }

    // MARK: - Core Audio queries

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var deviceAliveAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var address = defaultInputAddress
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    static func hogPID(of device: AudioDeviceID) -> pid_t? {
        var hog: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &hog)
        guard status == noErr else { return nil }
        return hog
    }

    private struct NativeFormat {
        let asbd: AudioStreamBasicDescription
    }

    private static func nativeFormat(of device: AudioDeviceID) -> NativeFormat {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &description) == noErr,
           description.mSampleRate > 0,
           description.mChannelsPerFrame > 0 {
            return NativeFormat(asbd: description)
        }
        description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        return NativeFormat(asbd: description)
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
        return defaultInputDevice().flatMap(name(of:))
    }

    static func name(of deviceID: AudioDeviceID) -> String? {
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
