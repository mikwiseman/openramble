import AVFoundation
import CoreAudio
import Darwin
import DictationCore
import Foundation

/// The microphone for one take.
///
/// Only the key-down opens it, so everything `open` and `start` do is time
/// the person may already be speaking into. On the built-in microphone an
/// AVAudioEngine graph took a median ~200 ms from that call to the first
/// captured sample; the device itself was live in ~45 ms through a HAL I/O
/// proc. Speech that began 0-150 ms after the press kept its first word
/// whole in 3 of 77 takes (research/first-word-2026-10).
protocol CaptureInput: AnyObject, Sendable {
    /// What the handler receives: the device's own format.
    var format: AVAudioFormat { get }
    /// Set once, before `start`.
    func install(_ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)
    /// May block inside Core Audio, so it runs on the start lane.
    func start() throws
    /// May block inside Core Audio, so it runs on the teardown lane.
    func stop()
}

typealias CaptureInputOpener = @Sendable (AudioDeviceID?) throws -> any CaptureInput

enum CaptureInputs {
    /// The I/O proc, unless the device refuses it; then the engine, which is
    /// exactly what every take used before.
    static func open(_ device: AudioDeviceID?) throws -> any CaptureInput {
        if let input = HALCaptureInput(device: device) { return input }
        return try EngineCaptureInput(device: device)
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

    private final class HandlerSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

        func set(_ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
            lock.withLock { self.handler = handler }
        }

        func get() -> (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? {
            lock.withLock { handler }
        }
    }

    /// `nil` when the I/O proc cannot carry this device: none at all, another
    /// process holding it exclusively, several input streams, or a format
    /// that does not describe itself. The engine handles each of those the
    /// way it always has.
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
        guard Self.inputStreamCount(of: device) == 1,
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
        destroy()
    }

    func install(_ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        slot.set(handler)
    }

    func start() throws {
        let status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            throw AudioCaptureError.engineUnavailable("the microphone could not be started (\(status))")
        }
    }

    func stop() {
        AudioDeviceStop(device, procID)
        destroy()
    }

    private func destroy() {
        let shouldDestroy = lock.withLock {
            defer { destroyed = true }
            return !destroyed
        }
        if shouldDestroy { AudioDeviceDestroyIOProcID(device, procID) }
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
/// fallback for a device the I/O proc cannot carry.
final class EngineCaptureInput: CaptureInput, @unchecked Sendable {
    let format: AVAudioFormat

    private let engine = AVAudioEngine()
    private let input: AVAudioInputNode

    init(device: AudioDeviceID?) throws {
        input = engine.inputNode
        // Point the engine at the chosen microphone before anything reads a
        // format from it. After that the node has already negotiated with a
        // device and changing it is ignored.
        if let device { try Self.select(device, on: input) }
        format = input.outputFormat(forBus: 0)
    }

    func install(_ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
            handler(buffer, when)
        }
    }

    func start() throws {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineUnavailable(error.localizedDescription)
        }
    }

    func stop() {
        engine.stop()
        input.removeTap(onBus: 0)
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
