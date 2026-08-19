import CoreAudio
import Foundation

/// One microphone the machine can hear through.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    /// The stable name for a device across reboots and replugs.
    ///
    /// Not the numeric `AudioDeviceID`: those are handed out per boot and get
    /// reused, so a stored one can point at a different device tomorrow — or
    /// at the wrong one after unplugging a dock. Storing the UID means a
    /// chosen microphone is still the same microphone next week.
    public let uid: String
    public let name: String

    public var id: String { uid }
}

/// Asks CoreAudio what can record.
public enum AudioInputDevices {
    /// Every device with at least one input channel.
    ///
    /// Output-only devices are excluded by asking for their input stream
    /// configuration rather than by name: a display with speakers and a
    /// webcam-less HDMI link both call themselves plausible things.
    public static func available() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id), let uid = uid(of: id), let name = name(of: id) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// Turn a stored UID back into something CoreAudio will accept, or `nil`
    /// when that microphone is not on this machine right now.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        available().first { $0.uid == uid }.flatMap { device in
            rawIDs().first { self.uid(of: $0) == device.uid }
        }
    }

    private static func rawIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr
        else { return false }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        string(from: id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func name(of id: AudioDeviceID) -> String? {
        string(from: id, selector: kAudioObjectPropertyName)
    }

    private static func string(from id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Unmanaged, because CoreAudio hands back a +1 CFString through a raw
        // buffer. Taking the address of a `CFString` variable instead lets the
        // compiler move an object reference under the API's feet.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        let text = value.takeRetainedValue() as String
        return text.isEmpty ? nil : text
    }
}
