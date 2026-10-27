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
    /// Set once: before `start`, or after it when `handlerMayFollowStart`.
    /// `onLost` runs at most once, on any thread, when the device disappears
    /// or changes its format under a running take: from then on nothing it
    /// delivers can be trusted.
    func install(_ handler: @escaping CaptureHandler, onLost: @escaping @Sendable () -> Void)
    /// Whether the device may start before `install` and hold what it hears
    /// until a handler arrives, so a take's microphone starts before the
    /// converter it needs has been built.
    var handlerMayFollowStart: Bool { get }
    /// May block inside Core Audio, so it runs on the start lane.
    func start() throws
    /// May block inside Core Audio, so it runs on the teardown lane. Safe on
    /// a microphone that was opened but never started.
    func stop()
}

extension CaptureInput {
    var handlerMayFollowStart: Bool { false }
}

/// Receives each buffer in the device's format. On an I/O proc the buffer is
/// the device's own memory, valid only until the handler returns.
typealias CaptureHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

/// The smallest piece of a take that the meter and the segmenter look at.
///
/// The engine tap delivers about 100 ms per buffer (1,530-1,600 samples at
/// 16 kHz on this Mac), and both were tuned on that: the waveform's 24 bars
/// span about 2.4 s, each the peak of one buffer, and the segmenter's pauses
/// were measured with whole buffers counting as speech. An I/O proc cycle is
/// 10.7 ms. Every cycle still goes to the recording the moment it arrives;
/// only these two gather cycles until they hold at least this much. 90 ms
/// sits just under the engine's buffer, so each engine buffer still passes
/// alone and nine I/O proc cycles make one block.
enum CaptureBlock {
    static let minimumSamples = 1_440
}

typealias CaptureInputOpener = @Sendable (AudioDeviceID?) throws -> any CaptureInput

enum CaptureInputs {
    static let kept = KeptMicrophone<HALCaptureInput>()

    /// The last take's I/O proc while it is still the one this take would
    /// open; else a new I/O proc, unless the device is one it does not carry;
    /// then the engine, which is exactly what every take used before.
    static func open(_ device: AudioDeviceID?) throws -> any CaptureInput {
        kept.watchSystem()
        if let input = kept.reopen(for: device) { return input }
        if let input = HALCaptureInput(device: device) { return input }
        return try EngineCaptureInput(device: device)
    }

    /// The device's own stream format, as an I/O proc hands it over.
    ///
    /// AVAudioFormat describes more than two channels only with a layout, and
    /// a device's input channels have none to give: a Mac's built-in
    /// microphones while a call holds voice processing (three), or a
    /// multi-input interface. They are named as what they are, discrete.
    static func format(of description: AudioStreamBasicDescription) -> AVAudioFormat? {
        var description = description
        guard description.mChannelsPerFrame > 2 else { return AVAudioFormat(streamDescription: &description) }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | description.mChannelsPerFrame
        ) else { return nil }
        return AVAudioFormat(streamDescription: &description, channelLayout: layout)
    }

    /// What a reader of the device is told about. Being disconnected and
    /// changing format are the same news: the stream it opened is gone.
    static let watched: [AudioObjectPropertyAddress] = [
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

    /// Whether the device still delivers the stream a reader opened as
    /// `format`: alive, at the same rate and channel count. A call that turns
    /// voice processing on takes a Mac's built-in microphones from one
    /// channel to three, and back when it ends; every I/O cycle after that
    /// no longer fits the format and is dropped.
    static func delivers(_ format: AVAudioFormat, from device: AudioDeviceID) -> Bool {
        var address = watched[0]
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr, alive != 0 else {
            return false
        }
        return isSameStream(inputFormat(of: device), as: format)
    }

    static func isSameStream(_ current: AudioStreamBasicDescription?, as opened: AVAudioFormat) -> Bool {
        guard let current else { return false }
        return current.mSampleRate == opened.sampleRate && current.mChannelsPerFrame == opened.channelCount
    }

    static func inputFormat(of device: AudioDeviceID) -> AudioStreamBasicDescription? {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = watched[2]
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &description) == noErr,
              description.mSampleRate > 0,
              description.mChannelsPerFrame > 0
        else { return nil }
        return description
    }
}

/// What a stopped microphone needs for the next take to use it again.
protocol ReopenableCaptureInput: AnyObject, Sendable {
    /// What its take asked for: a device, or the default input.
    var request: AudioDeviceID? { get }
    /// `KeptMicrophone.epoch` when it opened.
    var epoch: Int { get }
    /// Ready for another take; false once it can no longer be trusted.
    func reopen() -> Bool
}

/// The last take's microphone, still registered with its device but stopped,
/// so the next take does not open one.
///
/// Opening is a run of round trips to `coreaudiod`, and on the first take
/// after the Mac paged OpenRamble out it is the part of key-down → device
/// started that grows with the paging (research/stress-lab-2026-10). An I/O
/// proc that is registered but not started does not run the device: nothing
/// is heard, and the menu bar shows no microphone. It is let go whenever it
/// may no longer be what a take would open: the default input changing, Core
/// Audio restarting, or its own device disappearing or changing format.
final class KeptMicrophone<Input: ReopenableCaptureInput>: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: Input?
    private var changes = 0
    private var watching = false
    private let queue = DispatchQueue(label: "is.waiwai.dictation.kept-microphone")

    /// Counts the changes that make a kept microphone the wrong one. One
    /// opened before the latest is never kept.
    var epoch: Int { lock.withLock { changes } }

    /// The kept microphone, ready for a new take, if it is the one `request`
    /// would open. Whatever else was kept is let go.
    func reopen(for request: AudioDeviceID?) -> Input? {
        let input: Input? = lock.withLock {
            defer { kept = nil }
            return kept
        }
        guard let input, input.request == request, input.reopen() else { return nil }
        return input
    }

    /// Called by a microphone that has stopped after a clean start. False
    /// when it opened before a change, and is not kept.
    func keep(_ input: Input) -> Bool {
        var replaced: Input?
        let kept: Bool = lock.withLock {
            guard input.epoch == changes else { return false }
            replaced = self.kept
            self.kept = input
            return true
        }
        withExtendedLifetime(replaced) {}
        return kept
    }

    /// The default input changed, or Core Audio restarted.
    func changed() {
        let dropped: Input? = lock.withLock {
            changes += 1
            defer { kept = nil }
            return kept
        }
        withExtendedLifetime(dropped) {}
    }

    /// From the first take on, hears about the changes that make a kept
    /// microphone the wrong one.
    func watchSystem() {
        guard lock.withLock({ () -> Bool in
            defer { watching = true }
            return !watching
        }) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyServiceRestarted] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
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

/// Carries each I/O cycle off the device's real-time thread.
///
/// The I/O proc used to run on a dispatch queue, and the HAL waits for that
/// queue inside its cycle. Whenever the queue's thread was late, the device
/// skipped the cycle and its audio was gone: after a rest under memory
/// pressure every take lost some, up to a 100 ms hole at the start, and an
/// overloaded Mac lost cycles mid-take (research/stress-lab-2026-10). Now the
/// real-time thread only copies the cycle into memory allocated when the
/// microphone opened, and a worker thread hands it to the capture. A late
/// worker delays audio instead of losing it, for about `tolerance` of audio.
/// Past that the take is told its microphone was lost, and keeps what it
/// has, rather than recording a hole nobody hears.
final class CaptureRing: @unchecked Sendable {
    /// How late the worker may fall behind before a cycle would be lost.
    static let tolerance: Double = 2.7
    /// Never more than this for the slots, whatever the device: a
    /// many-channel interface with long cycles must not cost hundreds of MB.
    static let memoryLimit = 16 << 20

    let slotCount: Int
    private let format: AVAudioFormat
    private let buffers: [AVAudioPCMBuffer]
    /// Per slot, per AudioBuffer: where the cycle's bytes go and how many fit.
    /// Read on the real-time thread, so plain pointers rather than objects.
    private let destinations: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private let capacities: UnsafeMutablePointer<Int>
    private let bufferCount: Int
    private let bytesPerFrame: Int
    private let frames: UnsafeMutablePointer<AVAudioFrameCount>
    private let times: UnsafeMutablePointer<AudioTimeStamp>
    /// Guards the indices only, never a copy or a handler call: the
    /// real-time thread holds it for a few instructions.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var head = 0
    private var tail = 0
    private var count = 0
    private var overflowed = false
    private var stopping = false
    private var finishing = false
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    /// `nil` for a format whose cycles cannot be copied as plain bytes.
    init?(format: AVAudioFormat, framesPerCycle: Int) {
        let audioBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let bytes = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytes > 0, audioBuffers > 0 else { return nil }
        let capacity = AVAudioFrameCount(max(framesPerCycle, 512) * 2)
        let cycles = Int(Self.tolerance * format.sampleRate) / max(framesPerCycle, 1)
        let affordable = Self.memoryLimit / max(Int(capacity) * bytes * audioBuffers, 1)
        let slotCount = max(16, min(cycles, affordable))
        var buffers: [AVAudioPCMBuffer] = []
        for _ in 0..<slotCount {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            buffers.append(buffer)
        }
        self.slotCount = slotCount
        self.format = format
        self.buffers = buffers
        bufferCount = audioBuffers
        bytesPerFrame = bytes
        destinations = .allocate(capacity: slotCount * audioBuffers)
        capacities = .allocate(capacity: slotCount * audioBuffers)
        for (slot, buffer) in buffers.enumerated() {
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard list.count == audioBuffers else { return nil }
            for (index, audioBuffer) in list.enumerated() {
                destinations[slot * audioBuffers + index] = audioBuffer.mData
                capacities[slot * audioBuffers + index] = Int(capacity) * bytes
                // Touch every page now, on the start lane, so the real-time
                // thread never takes a fault on a page nobody wrote yet.
                if let data = audioBuffer.mData { memset(data, 0, Int(capacity) * bytes) }
            }
        }
        frames = .allocate(capacity: slotCount)
        times = .allocate(capacity: slotCount)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        destinations.deallocate()
        capacities.deallocate()
        frames.deallocate()
        times.deallocate()
        lock.deallocate()
    }

    /// The I/O proc's whole job. Real-time thread: no allocation, no waiting.
    func write(_ input: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
        os_unfair_lock_lock(lock)
        let full = count == slotCount
        if full { overflowed = true }
        let slot = head
        os_unfair_lock_unlock(lock)
        guard !full else {
            ready.signal()
            return
        }
        copy(input, at: time, into: slot)
        os_unfair_lock_lock(lock)
        head = (head + 1) % slotCount
        count += 1
        os_unfair_lock_unlock(lock)
        ready.signal()
    }

    private func copy(_ input: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>, into slot: Int) {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var length = 0
        for index in 0..<min(source.count, bufferCount) {
            let bytes = min(Int(source[index].mDataByteSize), capacities[slot * bufferCount + index])
            if let data = source[index].mData, let destination = destinations[slot * bufferCount + index] {
                memcpy(destination, data, bytes)
            }
            length = bytes
        }
        frames[slot] = AVAudioFrameCount(length / bytesPerFrame)
        times[slot] = time.pointee
    }

    /// The worker: hands each cycle over in order, until `finish`. An
    /// overflow is reported from here, once, never from the real-time thread.
    ///
    /// Until `handler` returns one, cycles stay in the ring: a device started
    /// before its handler was installed loses nothing it heard meanwhile. A
    /// take that finishes with no handler at all failed to start, and what it
    /// held is let go.
    func run(_ handler: () -> CaptureHandler?, onOverflow: () -> Void) {
        var reported = false
        while true {
            ready.wait()
            let deliver = handler()
            while let deliver, let slot = next() {
                let buffer = buffers[slot]
                buffer.frameLength = frames[slot]
                if buffer.frameLength > 0 {
                    deliver(buffer, AVAudioTime(audioTimeStamp: times.advanced(by: slot), sampleRate: format.sampleRate))
                }
                os_unfair_lock_lock(lock)
                tail = (tail + 1) % slotCount
                count -= 1
                os_unfair_lock_unlock(lock)
            }
            os_unfair_lock_lock(lock)
            let done = stopping && (count == 0 || deliver == nil)
            let lost = overflowed
            os_unfair_lock_unlock(lock)
            if lost, !reported {
                reported = true
                onOverflow()
            }
            if done { break }
        }
        finished.signal()
    }

    /// After the device has stopped: let the worker hand over every cycle
    /// still queued, then wait for it. No cycle is dropped at the end of a
    /// take, which is where the last word lives. Only the first call waits.
    func finish() {
        os_unfair_lock_lock(lock)
        let first = !finishing
        finishing = true
        stopping = true
        os_unfair_lock_unlock(lock)
        guard first else { return }
        ready.signal()
        finished.wait()
    }

    private func next() -> Int? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return count > 0 ? tail : nil
    }
}

/// A HAL I/O proc on the input device, the way the recorder reads it.
///
/// Nothing is built before the device starts: no graph, no aggregate device,
/// no output side. The I/O proc runs on the device's real-time thread and
/// only copies each cycle into a `CaptureRing`; a worker thread gives it to
/// the handler. After a take that started cleanly it stays registered,
/// stopped, for the next one (`KeptMicrophone`); every take gets its own
/// handler, ring and worker.
final class HALCaptureInput: CaptureInput, ReopenableCaptureInput, @unchecked Sendable {
    let format: AVAudioFormat
    let request: AudioDeviceID?
    let epoch: Int

    private let device: AudioDeviceID
    private let framesPerCycle: Int
    private let writer: RingWriter
    private let lock = NSLock()
    private var procID: AudioDeviceIOProcID
    private var take: Take?
    /// A start has succeeded: the I/O proc works, and may be kept.
    private var proven = false
    /// Its device disappeared or changed format: it is never kept again.
    private var invalid = false
    private var destroyed = false
    private let listenerQueue = DispatchQueue(label: "is.waiwai.dictation.capture-device")
    private var listener: AudioObjectPropertyListenerBlock?

    final class HandlerSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: CaptureHandler?
        private var onLost: (@Sendable () -> Void)?
        private var lost = false
        private let reported = OnceFlag()

        /// A loss reported before the handler arrived is passed on now: the
        /// device starts first, and may change in between.
        func set(_ handler: @escaping CaptureHandler, onLost: @escaping @Sendable () -> Void) {
            let lostAlready = lock.withLock {
                self.handler = handler
                self.onLost = onLost
                return lost
            }
            if lostAlready { onLost() }
        }

        func get() -> CaptureHandler? {
            lock.withLock { handler }
        }

        func reportLost() {
            guard reported.claim() else { return }
            let onLost = lock.withLock {
                lost = true
                return self.onLost
            }
            onLost?()
        }
    }

    /// One take's handler, its ring, and the worker that empties it.
    private final class Take: @unchecked Sendable {
        let slot = HandlerSlot()
        let ring: CaptureRing
        /// Under the input's lock.
        var worker: Thread?

        init(ring: CaptureRing) {
            self.ring = ring
        }
    }

    /// The ring the I/O proc writes into: the current take's, replaced only
    /// while the device is stopped. The real-time thread holds the lock for
    /// one load.
    private final class RingWriter: @unchecked Sendable {
        private let lock: UnsafeMutablePointer<os_unfair_lock>
        private var ring: CaptureRing?

        init() {
            lock = .allocate(capacity: 1)
            lock.initialize(to: os_unfair_lock())
        }

        deinit { lock.deallocate() }

        func write(_ input: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
            os_unfair_lock_lock(lock)
            let ring = self.ring
            os_unfair_lock_unlock(lock)
            ring?.write(input, at: time)
        }

        func use(_ ring: CaptureRing?) {
            os_unfair_lock_lock(lock)
            self.ring = ring
            os_unfair_lock_unlock(lock)
        }
    }

    /// `nil` when the I/O proc cannot carry this device: none at all, another
    /// process holding it exclusively, several input streams, a format that
    /// does not describe itself, or Bluetooth. A Bluetooth headset can switch
    /// profile and format as its microphone opens, which is unmeasured on the
    /// I/O proc; the engine handles each of these the way it always has.
    init?(device preferred: AudioDeviceID?) {
        let epoch = CaptureInputs.kept.epoch
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
              let description = CaptureInputs.inputFormat(of: device),
              let format = CaptureInputs.format(of: description),
              format.sampleRate > 0,
              format.channelCount > 0
        else { return nil }

        let framesPerCycle = Self.framesPerCycle(of: device)
        let writer = RingWriter()
        guard let ring = CaptureRing(format: format, framesPerCycle: framesPerCycle),
              let made = Self.makeIOProc(on: device, writingTo: writer)
        else { return nil }
        writer.use(ring)
        self.request = preferred
        self.epoch = epoch
        self.device = device
        self.format = format
        self.framesPerCycle = framesPerCycle
        self.writer = writer
        self.procID = made
        self.take = Take(ring: ring)
        startListening()
    }

    deinit {
        destroy()
        if let take, take.worker != nil { take.ring.finish() }
    }

    /// No queue: the block runs on the HAL's own real-time thread, which
    /// waits for nothing of ours.
    private static func makeIOProc(on device: AudioDeviceID, writingTo writer: RingWriter) -> AudioDeviceIOProcID? {
        var made: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&made, device, nil) { _, inputData, inputTime, _, _ in
            writer.write(inputData, at: inputTime)
        }
        return status == noErr ? made : nil
    }

    func install(_ handler: @escaping CaptureHandler, onLost: @escaping @Sendable () -> Void) {
        lock.withLock { take?.slot }?.set(handler, onLost: onLost)
    }

    /// The ring holds every cycle until the handler is installed.
    var handlerMayFollowStart: Bool { true }

    /// A new handler slot and ring for the next take. The ring is new memory
    /// rather than the last take's, which the Mac may have paged out since:
    /// the real-time thread must never wait for a page.
    func reopen() -> Bool {
        guard let ring = CaptureRing(format: format, framesPerCycle: framesPerCycle) else { return false }
        let ready: Bool = lock.withLock {
            guard !invalid, !destroyed, take == nil else { return false }
            take = Take(ring: ring)
            return true
        }
        if ready { writer.use(ring) }
        return ready
    }

    func start() throws {
        guard let take = lock.withLock({ take }) else {
            throw AudioCaptureError.engineUnavailable("the microphone was not reopened")
        }
        // The buffer handed over is the ring's memory, valid only until the
        // handler returns, exactly like the device's own was.
        let ring = take.ring, slot = take.slot
        let worker = Thread {
            ring.run({ slot.get() }, onOverflow: { slot.reportLost() })
        }
        worker.name = "is.waiwai.dictation.capture-io"
        worker.qualityOfService = .userInteractive
        worker.start()
        let (procID, kept) = lock.withLock {
            take.worker = worker
            return (self.procID, proven)
        }
        var status = AudioDeviceStart(device, procID)
        // A kept I/O proc the HAL no longer has: register it again, once.
        if status != noErr, kept { status = reregister() }
        guard status == noErr else {
            lock.withLock { invalid = true }
            ring.finish()
            throw AudioCaptureError.engineUnavailable("the microphone could not be started (\(status))")
        }
        lock.withLock { proven = true }
    }

    func stop() {
        AudioDeviceStop(device, lock.withLock { procID })
        let (take, keep): (Take?, Bool) = lock.withLock {
            defer { self.take = nil }
            return (self.take, proven && !invalid && !destroyed)
        }
        // The device has stopped writing; hand over what it already wrote.
        if let take, lock.withLock({ take.worker }) != nil { take.ring.finish() }
        writer.use(nil)
        if keep, CaptureInputs.kept.keep(self) { return }
        destroy()
    }

    private func reregister() -> OSStatus {
        guard let made = Self.makeIOProc(on: device, writingTo: writer) else { return kAudioHardwareUnspecifiedError }
        let stale = lock.withLock {
            defer { procID = made }
            return procID
        }
        AudioDeviceDestroyIOProcID(device, stale)
        return AudioDeviceStart(device, made)
    }

    /// For the I/O proc's whole life, kept or running: a device that
    /// disappears or changes format ends the take on it, and is never used
    /// again.
    private func startListening() {
        let device = device
        let expected = format
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            if !CaptureInputs.delivers(expected, from: device) { self?.lost() }
        }
        lock.withLock { listener = block }
        for var address in CaptureInputs.watched {
            AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block)
        }
    }

    private func lost() {
        let slot: HandlerSlot? = lock.withLock {
            invalid = true
            return take?.slot
        }
        slot?.reportLost()
    }

    private func stopListening() {
        let block: AudioObjectPropertyListenerBlock? = lock.withLock {
            defer { listener = nil }
            return listener
        }
        guard let block else { return }
        for var address in CaptureInputs.watched {
            AudioObjectRemovePropertyListenerBlock(device, &address, listenerQueue, block)
        }
    }

    /// Unregisters for good: the listeners, then the I/O proc.
    private func destroy() {
        let procID: AudioDeviceIOProcID? = lock.withLock {
            defer { destroyed = true }
            return destroyed ? nil : self.procID
        }
        guard let procID else { return }
        stopListening()
        AudioDeviceDestroyIOProcID(device, procID)
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

    /// The device's I/O cycle in frames; 512 when it will not say.
    private static func framesPerCycle(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, value > 0 else {
            return 512
        }
        return Int(value)
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
