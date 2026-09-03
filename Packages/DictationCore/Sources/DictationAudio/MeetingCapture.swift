import AVFoundation
import DictationCore
import Foundation

/// A long recording: two sources in, one stereo file out, for as long as it
/// takes.
///
/// Nothing here holds audio in memory beyond a jitter window. Blocks arrive
/// from the sources' own threads, are placed on the shared timeline, and go
/// to disk; the file on disk is the recording, and everything else — levels
/// for the meters, health for the honesty strip, the summary at the end — is
/// derived from what passed through.
///
/// Recording is structurally separate from transcription. This actor lives
/// in `DictationAudio`, which cannot import the recognition package; its only
/// edge toward the engine is the frame count it exposes. A stalled decoder
/// cannot stop a recording, by the package graph rather than by promise.
public actor MeetingCapture {
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case paused
        case stopped
    }

    public enum Failure: Error, Sendable, Equatable {
        case notIdle
        case notRecording
        case cannotCreateDirectory(String)
        case writeFailed(String)
        case diskFull
        case microphone(MeetingSourceFailure)
        case systemAudio(MeetingSourceFailure)
    }

    /// The loudest sample per channel over the last stretch, 0…1, for meters.
    public struct Levels: Sendable, Equatable {
        public var microphone: Float
        public var system: Float
        public static let silent = Levels(microphone: 0, system: 0)

        public init(microphone: Float, system: Float) {
            self.microphone = microphone
            self.system = system
        }
    }

    /// Per-channel evidence for "is audio actually arriving?".
    public struct ChannelHealth: Sendable, Equatable {
        public var everDeliveredBuffers: Bool
        public var everDeliveredAudio: Bool
        public var lastBlockAt: ContinuousClock.Instant?
        public var lastAudibleAt: ContinuousClock.Instant?

        public init(
            everDeliveredBuffers: Bool,
            everDeliveredAudio: Bool,
            lastBlockAt: ContinuousClock.Instant? = nil,
            lastAudibleAt: ContinuousClock.Instant? = nil
        ) {
            self.everDeliveredBuffers = everDeliveredBuffers
            self.everDeliveredAudio = everDeliveredAudio
            self.lastBlockAt = lastBlockAt
            self.lastAudibleAt = lastAudibleAt
        }

        public static let none = ChannelHealth(everDeliveredBuffers: false, everDeliveredAudio: false)
    }

    /// What the recording turned out to be, handed back at stop.
    public struct Summary: Sendable, Equatable {
        public let frameCount: Int
        public let duration: TimeInterval
        public let microphoneDeviceName: String?
        public let systemAudio: SystemAudioSummary
        public let gaps: [MeetingGap]
        public let pauses: [MeetingInterval]
        public let endReason: MeetingEndReason

        public init(
            frameCount: Int,
            duration: TimeInterval,
            microphoneDeviceName: String?,
            systemAudio: SystemAudioSummary,
            gaps: [MeetingGap],
            pauses: [MeetingInterval],
            endReason: MeetingEndReason
        ) {
            self.frameCount = frameCount
            self.duration = duration
            self.microphoneDeviceName = microphoneDeviceName
            self.systemAudio = systemAudio
            self.gaps = gaps
            self.pauses = pauses
            self.endReason = endReason
        }
    }

    /// Anything above this counts as audio rather than line noise. Well
    /// below speech (0.02 is the segmenter's floor) so a quiet voice on the
    /// far side still proves the tap alive.
    public static let audibleThreshold: Float = 0.0005

    public let directory: URL
    public private(set) var state: State = .idle

    private let microphone: any MeetingAudioSource
    private let systemAudio: (any MeetingAudioSource)?
    private let pipeline: MeetingPipeline
    private let onFailure: @Sendable (Failure) -> Void
    /// Played when the other side starts being captured — see `SystemAudioProbe`.
    private let probe: @Sendable () -> Void
    private var startedAt: Date?
    private var pauses: [MeetingInterval] = []
    private var pausedAt: Date?
    private var endReason: MeetingEndReason?

    /// - Parameters:
    ///   - directory: where `audio.wav` and `peaks.bin` go; created if needed.
    ///   - systemAudio: `nil` records the microphone only, deliberately. The
    ///     file still has two channels so the format never changes.
    ///   - onLevels: meter updates, about ten a second, from a background queue.
    ///   - onFailure: the recording stopped itself, or one side did. Never
    ///     called for something the caller asked for.
    ///   - onSegment: a stretch of one channel that is on disk and worth a
    ///     decode. Delivered from a background queue, in file order per
    ///     channel, including the tails at pause and stop.
    public init(
        directory: URL,
        microphone: any MeetingAudioSource,
        systemAudio: (any MeetingAudioSource)?,
        segmentParameters: MeetingSegmentPolicy.Parameters = .meeting,
        onLevels: @escaping @Sendable (Levels) -> Void = { _ in },
        onSegment: @escaping @Sendable (MeetingSegmentRef) -> Void = { _ in },
        onFailure: @escaping @Sendable (Failure) -> Void = { _ in },
        freeBytes: @escaping @Sendable (URL) -> Int64? = MeetingCapture.freeBytes(at:),
        probe: @escaping @Sendable () -> Void = SystemAudioProbe.play
    ) {
        self.directory = directory
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.onFailure = onFailure
        self.probe = probe
        var active: Set<MeetingChannel> = [.microphone]
        if systemAudio != nil { active.insert(.system) }
        pipeline = MeetingPipeline(
            writer: MeetingWriter(directory: directory),
            activeChannels: active,
            segmentParameters: segmentParameters,
            onLevels: onLevels,
            onSegment: onSegment,
            freeBytes: { freeBytes(directory) }
        )
    }

    // MARK: - Reading

    /// Frames on disk: the recording's own clock, pauses excluded.
    public var frameCount: Int { pipeline.frameCount }
    public var duration: TimeInterval { Double(pipeline.frameCount) / Double(MeetingWriter.sampleRate) }
    public var levels: Levels { pipeline.levels }
    public func health(of channel: MeetingChannel) -> ChannelHealth { pipeline.health(of: channel) }
    public var audioURL: URL { pipeline.audioURL }

    // MARK: - Lifecycle

    public func start() throws {
        guard state == .idle else { throw Failure.notIdle }
        if let free = pipeline.freeBytes(), MeetingDiskPolicy.verdictToStart(freeBytes: free) == .tooLowToStart {
            throw Failure.diskFull
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotCreateDirectory(error.localizedDescription)
        }
        do {
            try pipeline.open()
        } catch {
            throw Failure.writeFailed(String(describing: error))
        }
        pipeline.anchor()
        try startSources()
        if systemAudio != nil { probe() }
        startedAt = Date()
        state = .recording
    }

    public func pause() throws {
        guard state == .recording else { throw Failure.notRecording }
        stopSources()
        pipeline.settle()
        pausedAt = Date()
        state = .paused
    }

    public func resume() throws {
        guard state == .paused else { throw Failure.notRecording }
        if let pausedAt, let startedAt {
            pauses.append(MeetingInterval(
                start: pausedAt.timeIntervalSince(startedAt),
                end: Date().timeIntervalSince(startedAt)
            ))
        }
        pausedAt = nil
        // The timeline is recording time, not wall time: re-anchor so the
        // next block lands right after the last one written.
        pipeline.anchor()
        try startSources()
        state = .recording
    }

    /// End the recording and make the file whole.
    ///
    /// The sources stop first, so nothing new arrives; then the pipeline
    /// flushes its jitter window and seals the file. That order is what
    /// keeps the last word: stopping the writer first would discard whatever
    /// was still in flight.
    public func stop() throws -> Summary {
        guard state == .recording || state == .paused else { throw Failure.notRecording }
        stopSources()
        if state == .paused, let pausedAt, let startedAt {
            pauses.append(MeetingInterval(
                start: pausedAt.timeIntervalSince(startedAt),
                end: Date().timeIntervalSince(startedAt)
            ))
        }
        state = .stopped
        let result = pipeline.finish()
        // A sealing failure is still a recording: whatever reached disk is
        // kept, and the reason travels in the summary rather than as a thrown
        // error that would lose the rest of it.
        let reason = endReason ?? (result.error == nil ? .stoppedByUser : .writeFailed)
        let systemHealth = pipeline.health(of: .system)
        let summary = Summary(
            frameCount: result.frameCount,
            duration: Double(result.frameCount) / Double(MeetingWriter.sampleRate),
            microphoneDeviceName: microphone.deviceName,
            systemAudio: SystemAudioSummary(
                wasRequested: systemAudio != nil,
                everDeliveredBuffers: systemHealth.everDeliveredBuffers,
                everDeliveredAudio: systemHealth.everDeliveredAudio,
                outputTransport: systemAudio?.deviceName
            ),
            gaps: result.gaps,
            pauses: pauses,
            endReason: reason
        )
        return summary
    }

    // MARK: - Sources

    private func startSources() throws {
        let pipeline = pipeline
        pipeline.onDiskOrWriteFailure = { [weak self] failure in
            guard let self else { return }
            Task { await self.pipelineFailed(failure) }
        }
        do {
            try microphone.start(
                onBlock: { pipeline.ingest(.microphone, $0) },
                onFailure: { [weak self] failure in
                    guard let self else { return }
                    Task { await self.sourceFailed(.microphone, failure) }
                }
            )
        } catch let failure as MeetingSourceFailure {
            throw Failure.microphone(failure)
        }
        guard let systemAudio else { return }
        do {
            try systemAudio.start(
                onBlock: { pipeline.ingest(.system, $0) },
                onFailure: { [weak self] failure in
                    guard let self else { return }
                    Task { await self.sourceFailed(.system, failure) }
                }
            )
        } catch let failure as MeetingSourceFailure {
            // The other side could not be started. The microphone is already
            // recording and stays that way: a permission that was not
            // granted must never cost the person the recording they pressed
            // the button for. It costs them a channel, and that is said.
            pipeline.markDown(.system, reason: .systemAudioStalled)
            onFailure(.systemAudio(failure))
        }
    }

    private func stopSources() {
        microphone.stop()
        systemAudio?.stop()
    }

    private func sourceFailed(_ channel: MeetingChannel, _ failure: MeetingSourceFailure) {
        guard state == .recording else { return }
        pipeline.markDown(
            channel,
            reason: channel == .microphone
                ? .microphoneUnavailable
                : (failure == .configurationChanged ? .systemAudioRouteChange : .systemAudioStalled)
        )
        switch (channel, failure) {
        case (.microphone, .configurationChanged):
            // The device moved; start again on whatever is default now. The
            // aligner fills the seconds in between with silence and the gap
            // is recorded, so the recording continues rather than ending.
            microphone.stop()
            do {
                try microphone.start(
                    onBlock: { [pipeline] in pipeline.ingest(.microphone, $0) },
                    onFailure: { [weak self] failure in
                        guard let self else { return }
                        Task { await self.sourceFailed(.microphone, failure) }
                    }
                )
            } catch let error as MeetingSourceFailure {
                onFailure(.microphone(error))
            } catch {
                onFailure(.microphone(.startFailed(String(describing: error))))
            }
        case (.microphone, _):
            onFailure(.microphone(failure))
        case (.system, .configurationChanged):
            // The output moved — AirPods came on, a display was plugged in.
            // A fresh tap follows the route; the seconds in between are a
            // gap on that channel, and the probe asks the new route whether
            // it can be heard at all.
            guard let systemAudio else { return }
            systemAudio.stop()
            do {
                try systemAudio.start(
                    onBlock: { [pipeline] in pipeline.ingest(.system, $0) },
                    onFailure: { [weak self] failure in
                        guard let self else { return }
                        Task { await self.sourceFailed(.system, failure) }
                    }
                )
                probe()
            } catch let error as MeetingSourceFailure {
                onFailure(.systemAudio(error))
            } catch {
                onFailure(.systemAudio(.startFailed(String(describing: error))))
            }
        case (.system, _):
            onFailure(.systemAudio(failure))
        }
    }

    private func pipelineFailed(_ failure: MeetingPipeline.Failure) {
        guard state == .recording else { return }
        switch failure {
        case .diskFull:
            endReason = .diskFull
            onFailure(.diskFull)
        case let .write(message):
            endReason = .writeFailed
            onFailure(.writeFailed(message))
        }
    }

    /// Free space where the recording lives, counting what the system could
    /// purge for something important — which a recording is.
    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// The part that runs off the actor: one serial queue that owns the clocks,
/// the aligner and the writer, so blocks from two threads are placed in the
/// order they are received and nothing is reordered by scheduling.
final class MeetingPipeline: @unchecked Sendable {
    enum Failure: Sendable, Equatable {
        case diskFull
        case write(String)
    }

    struct Result: Sendable {
        let frameCount: Int
        let gaps: [MeetingGap]
        let error: MeetingWriter.Failure?
    }

    private let queue = DispatchQueue(label: "is.waiwai.dictation.meeting-pipeline", qos: .userInitiated)
    private let writer: MeetingWriter
    private let activeChannels: Set<MeetingChannel>
    private let onLevels: @Sendable (MeetingCapture.Levels) -> Void
    private let onSegment: @Sendable (MeetingSegmentRef) -> Void
    private let segmentParameters: MeetingSegmentPolicy.Parameters
    private let freeBytesQuery: @Sendable () -> Int64?
    var onDiskOrWriteFailure: (@Sendable (Failure) -> Void)?
    /// One per active channel, fed with what was written — so a segment is a
    /// position in the file, never a position in memory.
    private var policies: [MeetingChannel: MeetingSegmentPolicy] = [:]
    private var crossTalk = CrossTalkGate()
    private var heldMicrophone: [(peak: Float, count: Int)] = []
    private var heldMicrophoneFrames = 0

    // Owned by `queue`.
    private var clocks: [MeetingChannel: ChannelClock] = [:]
    private var aligner: DualChannelAligner
    private var anchorNanoseconds: UInt64 = 0
    private var anchorFrame = 0
    private var failed = false
    private var gaps: [MeetingGap] = []
    private var downSince: [MeetingChannel: (frame: Int, reason: MeetingGap.Reason)] = [:]
    private var nextDiskCheckFrame = MeetingDiskPolicy.checkEveryFrames
    private var levelWindow = MeetingCapture.Levels.silent
    private var levelWindowFrames = 0

    // Read from any thread.
    private let lock = NSLock()
    private var publishedLevels = MeetingCapture.Levels.silent
    private var channelHealth: [MeetingChannel: MeetingCapture.ChannelHealth] = [:]

    init(
        writer: MeetingWriter,
        activeChannels: Set<MeetingChannel>,
        segmentParameters: MeetingSegmentPolicy.Parameters,
        onLevels: @escaping @Sendable (MeetingCapture.Levels) -> Void,
        onSegment: @escaping @Sendable (MeetingSegmentRef) -> Void,
        freeBytes: @escaping @Sendable () -> Int64?
    ) {
        self.writer = writer
        self.activeChannels = activeChannels
        self.segmentParameters = segmentParameters
        self.onLevels = onLevels
        self.onSegment = onSegment
        freeBytesQuery = freeBytes
        aligner = DualChannelAligner(activeChannels: activeChannels)
        for channel in activeChannels {
            policies[channel] = MeetingSegmentPolicy(channel: channel, parameters: segmentParameters)
        }
    }

    var audioURL: URL { writer.audioURL }
    var frameCount: Int { writer.frameCount }

    var levels: MeetingCapture.Levels {
        lock.lock()
        defer { lock.unlock() }
        return publishedLevels
    }

    func health(of channel: MeetingChannel) -> MeetingCapture.ChannelHealth {
        lock.lock()
        defer { lock.unlock() }
        return channelHealth[channel] ?? .none
    }

    func freeBytes() -> Int64? { freeBytesQuery() }

    func open() throws {
        try writer.open()
    }

    /// Set "now" to be the frame after the last one written. Called at start
    /// and at every resume, so the timeline is recording time.
    func anchor() {
        let now = UInt64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000)
        queue.sync {
            anchorNanoseconds = now
            anchorFrame = writer.frameCount
            for channel in MeetingChannel.allCases { clocks[channel] = ChannelClock() }
            aligner = DualChannelAligner(activeChannels: activeChannels)
            crossTalk.reset()
            heldMicrophone = []
            heldMicrophoneFrames = 0
            // The aligner starts its cursor at zero; the file does not.
            // Anything it emits is offset by where the file already is.
        }
    }

    /// Let the queue run dry before a pause, so nothing arrives after the
    /// sources have been told to stop.
    func settle() {
        queue.sync {
            if let emission = aligner.flush() { write(emission) }
            flushSegments()
        }
    }

    func ingest(_ channel: MeetingChannel, _ block: MeetingAudioBlock) {
        queue.async { [self] in
            guard !failed else { return }
            let peak = block.samples.reduce(0) { max($0, abs($1)) }
            noteHealth(channel, peak: peak)
            let hostFrame: Int? = block.hostNanoseconds.map { ns in
                let elapsed = Double(Int64(bitPattern: ns &- anchorNanoseconds)) / 1_000_000_000
                return Int((elapsed * Double(MeetingWriter.sampleRate)).rounded())
            }
            // The defaulting subscript mutates in place, so this is one
            // placement, on the stored clock.
            let placement = clocks[channel, default: ChannelClock()]
                .place(hostFrame: hostFrame, sampleCount: block.samples.count)
            closeGapIfDown(channel)
            aligner.ingest(channel: channel, startFrame: placement.startFrame, samples: block.samples)
            if let emission = aligner.drain() { write(emission) }
            accumulateLevels(channel, peak: peak, frames: block.samples.count)
        }
    }

    func markDown(_ channel: MeetingChannel, reason: MeetingGap.Reason) {
        queue.async { [self] in
            guard downSince[channel] == nil else { return }
            downSince[channel] = (writer.frameCount, reason)
        }
    }

    func finish() -> Result {
        queue.sync {
            // A writer that already failed is not written to again: the
            // flush would only re-raise the same failure.
            if !failed, let emission = aligner.flush() { write(emission) }
            flushSegments()
            for (channel, down) in downSince {
                gaps.append(MeetingGap(
                    channel: channel,
                    start: seconds(down.frame),
                    end: seconds(writer.frameCount),
                    reason: down.reason
                ))
            }
            downSince = [:]
            var writeError: MeetingWriter.Failure?
            do {
                try writer.finish()
            } catch let failure as MeetingWriter.Failure {
                writeError = failure
            } catch {
                writeError = .writeFailed(String(describing: error))
            }
            return Result(frameCount: writer.frameCount, gaps: gaps, error: writeError)
        }
    }

    // MARK: - On the queue

    private func write(_ emission: DualChannelAligner.Emission) {
        do {
            try writer.append(microphone: emission.microphone, system: emission.system)
        } catch {
            failed = true
            onDiskOrWriteFailure?(.write(String(describing: error)))
            return
        }
        // Only after the append: a segment must never name frames that are
        // not on disk yet.
        //
        // With both sides recorded, the speakers leak into the microphone;
        // a block where the system side is clearly the louder one is not the
        // person speaking, and the microphone segmenter is told silence for
        // it. The file keeps the audio either way.
        let microphoneIsEcho = activeChannels.contains(.system)
            && crossTalk.classify(microphone: emission.microphone, system: emission.system).isEcho
        for channel in activeChannels {
            let samples = channel == .microphone ? emission.microphone : emission.system
            let peak = samples.reduce(0) { max($0, abs($1)) }
            if channel == .microphone, activeChannels.contains(.system) {
                holdMicrophone(peak: peak, count: samples.count, isEcho: microphoneIsEcho)
            } else if let segment = policies[channel]?.observe(peak: peak, count: samples.count) {
                onSegment(segment)
            }
        }
        if writer.frameCount >= nextDiskCheckFrame {
            nextDiskCheckFrame = writer.frameCount + MeetingDiskPolicy.checkEveryFrames
            if let free = freeBytesQuery(), MeetingDiskPolicy.mustStop(freeBytes: free) {
                failed = true
                onDiskOrWriteFailure?(.diskFull)
            }
        }
    }

    private func flushSegments() {
        releaseMicrophone(keeping: 0)
        for channel in activeChannels {
            if let tail = policies[channel]?.flush() { onSegment(tail) }
        }
    }

    /// Microphone frames wait a fifth of a second before reaching the
    /// segmenter. The gate decides over a window and its decision belongs to
    /// the whole window, but blocks arrive a few milliseconds at a time and
    /// the first of a remote sentence are judged before there is anything
    /// to match against. Held back, they are still here to be told silence
    /// when the match arrives; released too soon, one of them is enough for
    /// the segmenter to bring the sentence back as a paragraph. Frames reach
    /// the segmenter in order and in full; only later.
    static let microphoneLookaheadFrames = 3_200

    private func holdMicrophone(peak: Float, count: Int, isEcho: Bool) {
        heldMicrophone.append((peak: isEcho ? 0 : peak, count: count))
        heldMicrophoneFrames += count
        if isEcho {
            for index in heldMicrophone.indices { heldMicrophone[index].peak = 0 }
        }
        releaseMicrophone(keeping: Self.microphoneLookaheadFrames)
    }

    private func releaseMicrophone(keeping lookahead: Int) {
        while let first = heldMicrophone.first, heldMicrophoneFrames - first.count >= lookahead {
            heldMicrophone.removeFirst()
            heldMicrophoneFrames -= first.count
            if let segment = policies[.microphone]?.observe(peak: first.peak, count: first.count) {
                onSegment(segment)
            }
        }
    }

    private func closeGapIfDown(_ channel: MeetingChannel) {
        guard let down = downSince.removeValue(forKey: channel) else { return }
        gaps.append(MeetingGap(
            channel: channel,
            start: seconds(down.frame),
            end: seconds(writer.frameCount),
            reason: down.reason
        ))
    }

    private func seconds(_ frame: Int) -> TimeInterval {
        Double(frame) / Double(MeetingWriter.sampleRate)
    }

    private func noteHealth(_ channel: MeetingChannel, peak: Float) {
        let now = ContinuousClock.now
        lock.lock()
        var health = channelHealth[channel] ?? .none
        health.everDeliveredBuffers = true
        health.lastBlockAt = now
        if peak >= MeetingCapture.audibleThreshold {
            health.everDeliveredAudio = true
            health.lastAudibleAt = now
        }
        channelHealth[channel] = health
        lock.unlock()
    }

    /// Publish the loudest sample per channel about ten times a second.
    private func accumulateLevels(_ channel: MeetingChannel, peak: Float, frames: Int) {
        switch channel {
        case .microphone: levelWindow.microphone = max(levelWindow.microphone, peak)
        case .system: levelWindow.system = max(levelWindow.system, peak)
        }
        levelWindowFrames += frames
        guard levelWindowFrames >= PeakFile.defaultFramesPerBucket else { return }
        let published = levelWindow
        levelWindow = .silent
        levelWindowFrames = 0
        lock.lock()
        publishedLevels = published
        lock.unlock()
        onLevels(published)
    }
}
