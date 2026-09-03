import AVFoundation
import AudioToolbox
import CoreAudio
import DictationCore
import Foundation

/// Whether this Mac can record what it plays.
///
/// Core Audio process taps arrived in macOS 14.2. The app runs from 14.0, so
/// every tap symbol below sits behind `@available(macOS 14.2, *)`; the SDK
/// marks them for that version and the linker binds them weakly, which is
/// what lets the binary launch on 14.0 and 14.1 and simply record the
/// microphone there — with words, never silently.
public enum SystemAudioAvailability {
    public static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }
}

/// The other side of the call: what this Mac is playing, as a source.
///
/// A global process tap — everything the output device renders, excluding no
/// process — in a private aggregate device that holds only the tap. The
/// aggregate is deliberately not pinned to the user's output device: pinned,
/// it produces no buffers on Bluetooth and headphone routes even when the
/// permission is granted, which a sibling project learned the hard way.
///
/// Ported from that project's `SystemAudioCapture`, minus its crash reporter
/// (this app has none) and minus its real-time atomics (deprecated, and the
/// consumer derives health from what it receives anyway). The conversion to
/// 16 kHz mono goes through the same helpers the microphone uses, and the
/// converter is never reset between buffers — resetting leaves a seam in
/// every block.
///
/// What the tap cannot tell anyone: whether it is permitted. A denied tap is
/// created without error and delivers silence. That is the caller's problem
/// to detect, and `SystemAudioProbe` is how.
@available(macOS 14.2, *)
public final class SystemAudioTapSource: MeetingAudioSource, @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var tapID = AudioObjectID.max
    private var aggregateID = AudioObjectID.max
    private var ioProcID: AudioDeviceIOProcID?
    private var routeListener: (@Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void)?
    private var routeListenerBlock: AudioObjectPropertyListenerBlock?
    private var transport: String?

    public init() {}

    /// The output route's transport — built-in, bluetooth, airplay, usb — not
    /// a device name. It is the one fact worth keeping when the other side
    /// turns out to be missing.
    public var deviceName: String? {
        lock.lock()
        defer { lock.unlock() }
        return transport
    }

    public func start(
        onBlock: @escaping @Sendable (MeetingAudioBlock) -> Void,
        onFailure: @escaping @Sendable (MeetingSourceFailure) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard tapID == AudioObjectID.max else { throw MeetingSourceFailure.startFailed("already running") }

        let output = Self.defaultOutputDevice()
        transport = output.map(Self.transportName(of:))

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.name = "OpenRamble recording"
        description.isPrivate = true
        description.isExclusive = true

        var tap = AudioObjectID.max
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw MeetingSourceFailure.startFailed("the audio tap could not be created (\(status))") }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenRamble recording",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID.max
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingSourceFailure.startFailed("the audio tap device could not be created (\(status))")
        }

        let native = Self.nativeFormat(tap: tap, aggregate: aggregate, output: output)
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: native.sampleRate,
            channels: AVAudioChannelCount(native.channels),
            interleaved: native.interleaved
        ), let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingSourceFailure.startFailed("couldn't describe the tap's audio format")
        }
        let converter: AVAudioConverter?
        do {
            converter = try MicrophoneCapture.converter(from: sourceFormat, to: target) {
                AVAudioConverter(from: $0, to: $1)
            }
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingSourceFailure.startFailed(String(describing: error))
        }

        let reported = UncheckedBox(false)
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, inputData, inputTime, _, _ in
            // The buffer list is wrapped, not copied: the converter reads it
            // in place and hands back 16 kHz mono of its own.
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
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingSourceFailure.startFailed("the audio tap could not be read (\(status))")
        }
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, procID)
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingSourceFailure.startFailed("the audio tap could not be started (\(status))")
        }

        tapID = tap
        aggregateID = aggregate
        ioProcID = procID

        // The output route moved — to AirPods, to a display. Say so once; the
        // owner starts a fresh tap on whatever is default now and records the
        // seconds in between as a gap.
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { _, _ in onFailure(.configurationChanged) }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        routeListenerBlock = block
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let block = routeListenerBlock {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
            routeListenerBlock = nil
        }
        guard tapID != AudioObjectID.max else { return }
        // Stop, then destroy from the outside in: the IOProc, the device that
        // carried it, the tap the device was built on.
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        ioProcID = nil
        aggregateID = AudioObjectID.max
        tapID = AudioObjectID.max
    }

    // MARK: - Core Audio queries

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectSystemObject)
        var address = defaultOutputAddress
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    /// The tap's own format first; the aggregate's input scope if that is
    /// refused; the output device's nominal rate as a last resort — assuming
    /// stereo, which every output device this could be is.
    private struct NativeFormat {
        let sampleRate: Double
        let channels: Int
        let interleaved: Bool
    }

    private static func nativeFormat(tap: AudioObjectID, aggregate: AudioObjectID, output: AudioObjectID?) -> NativeFormat {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description) == noErr, description.mSampleRate > 0 {
            return NativeFormat(
                sampleRate: description.mSampleRate,
                channels: Int(max(1, description.mChannelsPerFrame)),
                interleaved: description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            )
        }
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &description) == noErr, description.mSampleRate > 0 {
            return NativeFormat(
                sampleRate: description.mSampleRate,
                channels: Int(max(1, description.mChannelsPerFrame)),
                interleaved: description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            )
        }
        if let output {
            var rate: Float64 = 0
            var rateSize = UInt32(MemoryLayout<Float64>.size)
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(output, &rateAddress, 0, nil, &rateSize, &rate) == noErr, rate > 0 {
                return NativeFormat(sampleRate: rate, channels: 2, interleaved: true)
            }
        }
        return NativeFormat(sampleRate: 48_000, channels: 2, interleaved: true)
    }

    static func transportName(of device: AudioObjectID) -> String {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return "unknown" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "continuity"
        default: return "other"
        }
    }
}

/// A quarter second of a 50 Hz tone at −40 dB, played through the default
/// output when a recording of the other side begins.
///
/// Laptop speakers reproduce nothing that low and nobody hears −40 dB, but
/// the tap sees the digital signal exactly. Measured: the built-in speakers'
/// processing removed a 10 Hz tone entirely before the tap point, while
/// 40 Hz arrived at its exact amplitude; and the tap sits before the volume
/// control — the same 0.0100 peak at volume 15 and volume 94 — so the tone
/// is seen at the same level whether the Mac is loud or nearly muted.
///
/// That turns an unanswerable question — is the other side actually being
/// captured, or was the permission denied, or is the output a Bluetooth
/// route the tap cannot reach? — into one with an answer inside three
/// seconds: a permitted tap on a reachable route reports this tone; anything
/// else stays at zero. Without it, a silent tap and a quiet call look
/// identical for as long as nobody speaks.
public enum SystemAudioProbe {
    public static let seconds = 0.25
    public static let hertz = 50.0
    public static let amplitude: Float = 0.01

    /// Plays and returns; the player is kept alive until it finishes.
    public static func play() {
        guard let player = try? AVAudioPlayer(data: wavData()) else { return }
        player.volume = 1
        player.play()
        // The player must outlive this call by a quarter second.
        let box = UncheckedBox(player)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds + 0.5) {
            box.value.stop()
        }
    }

    static func wavData(sampleRate: Int = 48_000) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var data = Data(capacity: 44 + frames * 4)
        func u32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 4))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 4))
        for frame in 0..<frames {
            let value = Int16(amplitude * 32_767 * Float(sin(2 * Double.pi * hertz * Double(frame) / Double(sampleRate))))
            u16(UInt16(bitPattern: value)); u16(UInt16(bitPattern: value))
        }
        return data
    }
}
