import AVFoundation
import CoreAudio
import Darwin
import DictationCore
import Foundation

/// The microphone for one take.
///
/// Only the key-down opens it, so everything `open` and `start` do is time
/// the person may already be speaking into. On the built-in microphone an
/// AVAudioEngine graph cost ~135 ms after the key-down before the device
/// started; a HAL I/O proc is live in ~48 ms. Either way the device itself
/// then needs ~180 ms before real sound arrives, which nothing that opens at
/// the key-down can remove (research/first-word-2026-10).
protocol CaptureInput: AnyObject, Sendable {
    /// What the handler receives: the device's own format.
    var format: AVAudioFormat { get }
    /// Set once, before `start`. `onLost` runs at most once, on any thread,
    /// when the device disappears or changes its format under a running take:
    /// from then on nothing it delivers can be trusted.
    func install(_ handler: @escaping CaptureHandler, onLost: @escaping @Sendable () -> Void)
    /// May block inside Core Audio, so it runs on the start lane.
    func start() throws
    /// May block inside Core Audio, so it runs on the teardown lane. Safe on
    /// a microphone that was opened but never started.
    func stop()
}

/// Receives each buffer in the device's format. On an I/O proc the buffer is
/// the device's own memory, valid only until the handler returns.
typealias CaptureHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

typealias CaptureInputOpener = @Sendable (AudioDeviceID?) throws -> any CaptureInput

enum CaptureInputs {
    /// The I/O proc, unless the device is one it does not carry; then the
    /// engine, which is exactly what every take used before.
    static func open(_ device: AudioDeviceID?) throws -> any CaptureInput {
        if let input = HALCaptureInput(device: device) { return input }
        return try EngineCaptureInput(device: device)
    }
}

/// Runs a closure once, from whichever thread gets there first.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.withLock {
            defer { used = true }
            return !used
        }
    }
}

/// A HAL I/O proc on the input device, the way the recorder reads it.
///
/// Nothing is built before the device starts: no graph, no aggregate device,
/// no output side. The handler gets each I/O cycle as the device delivers it.
final class HALCaptureInput: CaptureInput, @unchecked Sendable {
    let format: AVAudioFormat

    private let device: AudioDeviceID
    private let procID: AudioDeviceIOProcID
    private let slot: HandlerSlot
    private let lock = NSLock()
    private var destroyed = false
    private var listening = false
    private let listenerQueue = DispatchQueue(label: "is.waiwai.dictation.capture-device")
    private var listener: AudioObjectPropertyListenerBlock?

    /// What the take is told about. Being disconnected and changing format
    /// are the same news: the stream the take was opened on is gone.
    private static let watched: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        ),
    ]

    private final class HandlerSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: CaptureHandler?
        private var onLost: (@Sendable () -> Void)?
        private let lost = OnceFlag()

        func set(_ handler: @escaping CaptureHandler, onLost: @escaping @Sendable () -> Void) {
            lock.withLock {
                self.handler = handler
                self.onLost = onLost
            }
        }

        func get() -> CaptureHandler? {
            lock.withLock { handler }
        }

        func reportLost() {
            guard lost.claim() else { return }
            let onLost = lock.withLock { self.onLost }
            onLost?()
        }
    }

    /// `nil` when the I/O proc cannot carry this device: none at all, another
    /// process holding it exclusively, several input streams, a format that
    /// does not describe itself, or Bluetooth. A Bluetooth headset can switch
    /// profile and format as its microphone opens, which is unmeasured on the
    /// I/O proc; the engine handles each of these the way it always has.
    init?(device preferred: AudioDeviceID?) {
        guard let device = preferred ?? MicrophoneAudioSource.defaultInputDevice(), device != 0 else {
            return nil
        }
        if case .otherProcess = MicrophoneHogState.interpret(
            hogPID: MicrophoneAudioSource.hogPID(of: device) ?? -1,
            selfPID: getpid()
        ) {
            return nil
        }
        let transport = Self.transportType(of: device)
        guard transport != kAudioDeviceTransportTypeBluetooth,
              transport != kAudioDeviceTransportTypeBluetoothLE,
              Self.inputStreamCount(of: device) == 1,
              var description = Self.inputFormat(of: device),
              let format = AVAudioFormat(streamDescription: &description),
              format.sampleRate > 0,
              format.channelCount > 0
        else { return nil }

        let slot = HandlerSlot()
        let queue = DispatchQueue(label: "is.waiwai.dictation.capture-io", qos: .userInteractive)
        var made: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&made, device, queue) { _, inputData, inputTime, _, _ in
            guard let handler = slot.get(),
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: inputData,
                    deallocator: nil
                  ),
                  buffer.frameLength > 0
            else { return }
            // The buffer is the device's own memory, valid only inside this
            // call; the handler converts it before returning.
            handler(buffer, AVAudioTime(audioTimeStamp: inputTime, sampleRate: format.sampleRate))
        }
        guard status == noErr, let made else { return nil }
        self.device = device
        self.format = format
        self.procID = made
        self.slot = slot
    }

    deinit {
        stopListening()
        destroy()
    }

    func install(_ handler: @escaping CaptureHandler, onLost: @escaping @Sendable () -> Void) {
        slot.set(handler, onLost: onLost)
    }

    func start() throws {
        startListening()
        let status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            stopListening()
            throw AudioCaptureError.engineUnavailable("the microphone could not be started (\(status))")
        }
    }

    func stop() {
        stopListening()
        AudioDeviceStop(device, procID)
        destroy()
    }

    private func startListening() {
        let device = device
        let expected = format
        let slot = slot
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            let alive = (Self.uint32(device, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
            let current = Self.inputFormat(of: device)
            let unchanged = current.map {
                $0.mSampleRate == expected.sampleRate
                    && $0.mChannelsPerFrame == expected.channelCount
            } ?? false
            if !alive || !unchanged { slot.reportLost() }
        }
        lock.withLock {
            listener = block
            listening = true
        }
        for var address in Self.watched {
            AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block)
        }
    }

    private func stopListening() {
        let block: AudioObjectPropertyListenerBlock? = lock.withLock {
            defer {
                listening = false
                listener = nil
            }
            return listening ? listener : nil
        }
        guard let block else { return }
        for var address in Self.watched {
            AudioObjectRemovePropertyListenerBlock(device, &address, listenerQueue, block)
        }
    }

    private func destroy() {
        let shouldDestroy = lock.withLock {
            defer { destroyed = true }
            return !destroyed
        }
        if shouldDestroy { AudioDeviceDestroyIOProcID(device, procID) }
    }

    private static func uint32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func transportType(of device: AudioDeviceID) -> UInt32 {
        uint32(device, kAudioDevicePropertyTransportType) ?? 0
    }

    private static func inputStreamCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func inputFormat(of device: AudioDeviceID) -> AudioStreamBasicDescription? {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &description) == noErr,
              description.mSampleRate > 0,
              description.mChannelsPerFrame > 0
        else { return nil }
        return description
    }
}

/// AVAudioEngine's input node: what every take used before, and still the
/// path for a device the I/O proc does not carry.
final class EngineCaptureInput: CaptureInput, @unchecked Sendable {
    let format: AVAudioFormat

    private let engine = AVAudioEngine()
    private let input: AVAudioInputNode
    private let lock = NSLock()
    private var onLost: (@Sendable () -> Void)?
    private var observer: NSObjectProtocol?
    private var tapped = false

    init(device: AudioDeviceID?) throws {
        input = engine.inputNode
        // Point the engine at the chosen microphone before anything reads a
        // format from it. After that the node has already negotiated with a
        // device and changing it is ignored.
        if let device { try Self.select(device, on: input) }
        format = input.outputFormat(forBus: 0)
    }

    func install(_ handler: @escaping CaptureHandler, onLost: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.onLost = onLost
            tapped = true
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
            handler(buffer, when)
        }
    }

    func start() throws {
        // This engine's own configuration change, and nobody else's: another
        // engine in the process (playback, the recorder) changing its route
        // says nothing about this take's microphone.
        let lost = OnceFlag()
        let onLost = lock.withLock { self.onLost }
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            if lost.claim() { onLost?() }
        }
        lock.withLock { observer = token }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineUnavailable(error.localizedDescription)
        }
    }

    func stop() {
        if let token = lock.withLock({ () -> NSObjectProtocol? in
            defer { observer = nil }
            return observer
        }) {
            NotificationCenter.default.removeObserver(token)
        }
        engine.stop()
        if lock.withLock({ tapped }) { input.removeTap(onBus: 0) }
    }

    /// Refuses loudly rather than recording from the wrong microphone. Someone
    /// who chose a headset and silently got the laptop lid instead would only
    /// find out from the transcript, which is far too late.
    private static func select(_ id: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else {
            throw AudioCaptureError.engineUnavailable("no input unit to choose a microphone on")
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
            throw AudioCaptureError.engineUnavailable(
                "the chosen microphone didn't accept the recording (\(status))"
            )
        }
    }
}
