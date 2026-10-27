import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
@testable import DictationAudio
import DictationCore
import LocalASR
import XCTest

/// The shipping dictation path, end to end, while the Mac is overloaded.
///
/// Opt-in: it opens the built-in microphone, loads the real model and saturates
/// the machine, so `scripts/stress-lab.sh` sets it up and runs it, and every
/// other run skips it. All of `AppState` is the real one, and so is every edge
/// but two. The key is pressed in code. The microphone is opened, started and
/// read on its own audio thread exactly as in a take, but each buffer's samples
/// are replaced with a recorded sentence before the capture sees them — so
/// recognition has words to work on, and nothing the room says is kept. The
/// paste goes to a private named pasteboard, read by a second process the way
/// a target application reads ⌘V.
@MainActor
final class StressLab: XCTestCase {
    func testDictationUnderStress() async throws {
        guard let config = LabConfig(ProcessInfo.processInfo.environment) else {
            throw XCTSkip("Run scripts/stress-lab.sh; this suite opens the microphone and loads the model.")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Microphone access is not granted to this process; the lab never asks for it.")
        }
        let lab = try await Lab(config)
        do {
            for condition in config.conditions {
                try await lab.run(condition)
            }
            try lab.writeSummary()
        } catch {
            await lab.tearDown()
            throw error
        }
        await lab.tearDown()
    }
}

// MARK: - Configuration

struct LabConfig {
    struct Take {
        let name: String
        let audio: URL
        let reference: String
        let seconds: Double
    }

    let label: String
    let output: URL
    let engineDirectory: URL
    let takes: [Take]
    let hog: URL?
    let hogGigabytes: String
    let conditions: [String]
    let takesPerCondition: Int
    let idleTakes: Int
    let idleSeconds: Double

    init?(_ environment: [String: String]) {
        guard let output = environment["STRESS_LAB_OUT"],
              let engine = environment["STRESS_LAB_ENGINE"],
              let short = environment["STRESS_LAB_SHORT"],
              let shortText = environment["STRESS_LAB_SHORT_TEXT"] else { return nil }
        label = environment["STRESS_LAB_LABEL"] ?? "unlabelled"
        self.output = URL(fileURLWithPath: output, isDirectory: true)
        engineDirectory = URL(fileURLWithPath: engine, isDirectory: true)
        var takes = [Take(name: "short", audio: URL(fileURLWithPath: short), reference: shortText,
                          seconds: Self.duration(of: URL(fileURLWithPath: short)))]
        if let long = environment["STRESS_LAB_LONG"], let longText = environment["STRESS_LAB_LONG_TEXT"] {
            takes.append(Take(name: "long", audio: URL(fileURLWithPath: long), reference: longText,
                              seconds: Self.duration(of: URL(fileURLWithPath: long))))
        }
        self.takes = takes
        hog = environment["STRESS_LAB_HOG"].map { URL(fileURLWithPath: $0) }
        hogGigabytes = environment["STRESS_LAB_HOG_GB"] ?? "8"
        conditions = (environment["STRESS_LAB_CONDITIONS"] ?? "quiet,cpu,memory,both,idle")
            .split(separator: ",").map(String.init)
        takesPerCondition = Int(environment["STRESS_LAB_TAKES"] ?? "") ?? 12
        idleTakes = Int(environment["STRESS_LAB_IDLE_TAKES"] ?? "") ?? 3
        idleSeconds = Double(environment["STRESS_LAB_IDLE_SECONDS"] ?? "") ?? 240
    }

    private static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

// MARK: - The lab

@MainActor
final class Lab {
    private let config: LabConfig
    private let harness: AppHarness
    private let state: AppState
    private let reader: PasteReader
    private let injection = InjectionBox()
    private let heartbeat = MainThreadHeartbeat()
    private let stress = Stress()
    private var records: [TakeRecord] = []
    private var speedReports = 0
    private let journal: FileHandle

    init(_ config: LabConfig) async throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.output, withIntermediateDirectories: true)
        let journalURL = config.output.appending(path: "\(config.label)-takes.jsonl")
        // Appended, never truncated: one label's conditions run as separate
        // processes, interleaved with the other label's.
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            FileManager.default.createFile(atPath: journalURL.path, contents: nil)
        }
        journal = try FileHandle(forWritingTo: journalURL)
        try journal.seekToEnd()

        harness = try AppHarness()
        harness.defaults.set(true, forKey: "onboardingCompleted")
        try harness.installModel(cloningFrom: config.engineDirectory)
        harness.recognizer = LocalTranscriber(engine: TranscribeCppAdapter())

        let board = "is.waiwai.dictation.stress-lab.\(UUID().uuidString)"
        reader = try PasteReader(board: board)
        let target = TargetApplication(bundleIdentifier: "is.waiwai.dictation.stress-lab-target",
                                       processIdentifier: reader.processIdentifier,
                                       localizedName: "Stress lab target")
        harness.targetOverride = target
        harness.inserterOverride = TextInserter(
            system: LabInputSystem(target: target, reader: reader),
            pasteboard: HostOnlyPasteboard(name: board),
            operationLane: TextInsertionLane()
        )
        harness.overlayOverride = DictationOverlay(announcer: FakeAnnouncer())
        let speech = try config.takes.map { try SpeechSource(url: $0.audio) }
        let injection = injection
        harness.makeCaptureOverride = { directory, failure, samples, memoryLimit, device in
            MicrophoneCapture(
                directory: directory,
                onFailure: failure,
                onSamples: samples,
                onMemoryLimitReached: memoryLimit,
                preferredInputDeviceID: device,
                openInput: { device in
                    let began = mach_absolute_time()
                    let microphone = try CaptureInputs.open(device)
                    injection.noteOpen(began: began, ended: mach_absolute_time())
                    let input = SpeechOverMicrophone(microphone, speech: speech[injection.takeIndex])
                    injection.current = input
                    return input
                }
            )
        }

        state = harness.makeState()
        await state.refreshModelState()
        for _ in 0..<6_000 where !state.isEngineReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard state.isEngineReady else { throw LabError("the engine never became ready") }
        heartbeat.start()
    }

    /// The model goes before the process does: the runtime frees its Metal
    /// device from a static destructor at exit, and aborts if weights remain.
    func tearDown() async {
        heartbeat.stop()
        stress.stopAll()
        reader.stop()
        await harness.recognizer?.unload()
        try? journal.close()
        harness.tearDown()
    }

    func run(_ condition: String) async throws {
        switch condition {
        case "quiet":
            try await takes(condition)
        case "cpu":
            try stress.saturateCPU()
            try await takes(condition)
            stress.stopAll()
        case "memory":
            try stress.pressMemory(hog: config.hog, gigabytes: config.hogGigabytes)
            try await takes(condition)
            stress.stopAll()
        case "both":
            try stress.saturateCPU()
            try stress.pressMemory(hog: config.hog, gigabytes: config.hogGigabytes)
            try await takes(condition)
            stress.stopAll()
        case "pageout", "pageoutcpu":
            // The first take after the Mac pages the app out, quickly: a fresh
            // hog takes everyone's pages within seconds of claiming its own, so
            // each take here is the first one after a page-out. With "cpu",
            // every core is busy too, as on the Mac where the words were lost.
            if condition == "pageoutcpu" { try stress.saturateCPU() }
            defer { stress.stopAll() }
            // STRESS_LAB_FRESH=alternate: every other take lets the kept
            // microphone go and opens a new one, a paired comparison.
            let alternate = ProcessInfo.processInfo.environment["STRESS_LAB_FRESH"] == "alternate"
            for index in 0..<config.idleTakes {
                let fresh = alternate && index % 2 == 0
                if fresh { CaptureInputs.kept.changed() }
                try stress.pressMemory(hog: config.hog, gigabytes: config.hogGigabytes)
                try await Task.sleep(for: .seconds(10))
                let name = alternate ? condition + (fresh ? "-fresh" : "-kept") : condition
                try await take(config.takes[0], takeIndex: 0, condition: name, index: index)
                stress.stopHogs()
                try await Task.sleep(for: .seconds(10))
            }
        case "idle":
            // The 23 October shape: the model goes unused while the Mac is
            // short of memory, long enough for its weights to reach swap, and
            // then one take.
            try stress.pressMemory(hog: config.hog, gigabytes: config.hogGigabytes)
            for index in 0..<config.idleTakes {
                try await Task.sleep(for: .seconds(config.idleSeconds))
                try await take(config.takes[0], takeIndex: 0, condition: condition, index: index)
            }
            stress.stopAll()
        default:
            throw LabError("unknown condition \(condition)")
        }
    }

    private func takes(_ condition: String) async throws {
        // Let the load reach its level before measuring under it.
        if condition != "quiet" { try await Task.sleep(for: .seconds(5)) }
        for index in 0..<config.takesPerCondition {
            let takeIndex = index % config.takes.count
            try await take(config.takes[takeIndex], takeIndex: takeIndex, condition: condition, index: index)
        }
    }

    private func take(_ take: LabConfig.Take, takeIndex: Int, condition: String, index: Int) async throws {
        try await Task.sleep(for: .milliseconds(1_500))
        injection.takeIndex = takeIndex
        injection.current = nil
        let noticeBefore = state.lastNotice
        let speedBefore = state.lastSpeed
        let pastesBefore = reader.pastes.count
        let diskBefore = processDiskReadBytes()
        heartbeat.beginWindow()

        let clock = ContinuousClock()
        let pressed = clock.now
        let pressedMach = mach_absolute_time()
        harness.monitor.onPress?()
        let pressReturnedMach = mach_absolute_time()
        var listening: Duration?
        // The person speaks into the microphone the moment the key is down;
        // the injected sentence starts at its first buffer. Hold through it.
        let hold = Duration.milliseconds(Int((0.30 + take.seconds + 0.35) * 1_000))
        while pressed.duration(to: clock.now) < hold {
            if listening == nil, state.dictationState == .listening {
                listening = pressed.duration(to: clock.now)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let released = clock.now
        harness.monitor.onRelease?()
        while state.dictationState != .idle, released.duration(to: clock.now) < .seconds(90) {
            try await Task.sleep(for: .milliseconds(2))
        }
        let idleAgain = released.duration(to: clock.now)
        // The target's read is reported by the reader process a moment later.
        for _ in 0..<300 where reader.pastes.count == pastesBefore {
            try await Task.sleep(for: .milliseconds(10))
        }

        let window = heartbeat.endWindow()
        let report = state.lastSpeed != speedBefore ? state.lastSpeed : nil
        let pasted = reader.pastes.count > pastesBefore ? reader.pastes.last : nil
        let notice = state.lastNotice != noticeBefore ? state.lastNotice : nil
        let microphone = injection.current?.counters()
        let firstAudio = injection.current?.firstAudio().map { machMilliseconds(from: pressedMach, to: $0) }
        // Where key-down → first audio went, stage by stage.
        let opening = injection.takeOpening()
        let since = { (mark: UInt64?) in mark.map { machMilliseconds(from: pressedMach, to: $0) } }
        let startPath = StartPath(
            mainThread: machMilliseconds(from: pressedMach, to: pressReturnedMach),
            openBegan: since(opening?.began),
            openEnded: since(opening?.ended),
            startBegan: since(injection.current?.startBegan),
            startEnded: since(injection.current?.startEnded),
            firstBuffer: firstAudio
        )
        let record = TakeRecord(
            label: config.label,
            condition: condition,
            take: take.name,
            index: index,
            speechSeconds: take.seconds,
            keyDownToListening: listening?.ms,
            keyDownToFirstAudio: firstAudio,
            startPath: startPath,
            microphoneStartup: report?.microphoneStartup?.ms,
            releaseToText: report?.toRecognizedText.ms,
            releaseToPaste: report?.toPasteDispatched?.ms,
            releaseToRead: report?.toFirstRead?.ms,
            releaseToIdle: idleAgain.ms,
            captureFreeze: report?.phases?.captureFreeze.ms,
            recognition: report?.phases?.recognition.ms,
            engine: report?.phases?.engineProcessing?.ms,
            queued: report?.phases?.engineQueueing?.ms,
            streamedSegments: report?.phases?.streamedSegments,
            recordedSeconds: report?.phases.map { $0.audioDuration / .seconds(1) },
            landed: pasted != nil,
            wordsMissed: pasted.map { wordsMissed(reference: take.reference, output: $0) },
            notice: notice.map { "\($0.kind)" },
            deviceCallbacks: microphone?.callbacks,
            deviceFramesLost: microphone?.framesLost,
            deviceLongestCallbackGap: microphone?.longestGapMilliseconds,
            deviceLongestDelivery: microphone?.longestDeliveryMilliseconds,
            deviceFirstLossAt: microphone?.firstLossMilliseconds,
            mainThreadLongestStall: window.longest,
            mainThreadStallsOver50: window.over50,
            mainThreadStallsOver100: window.over100,
            mainThreadLongestStallAt: window.longestAt,
            diskReadBytes: processDiskReadBytes().flatMap { after in diskBefore.map { after &- $0 } },
            microphoneRunningAfter: defaultInputIsRunning(),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            loadAverage: loadAverage()
        )
        records.append(record)
        var line = try JSONEncoder.sorted.encode(record)
        line.append(10)
        try journal.write(contentsOf: line)
        print("stress-lab \(config.label) \(condition) \(take.name) #\(index): paste \(record.releaseToPaste.map { String(format: "%.0f", $0) } ?? "–") ms, landed \(record.landed)")
    }

    func writeSummary() throws {
        let summary = LabSummary(label: config.label, records: records)
        try summary.markdown().write(to: config.output.appending(path: "\(config.label)-summary.md"),
                                     atomically: true, encoding: .utf8)
        print(summary.markdown())
    }

    private func wordsMissed(reference: String, output: String) -> Int {
        let words = { (text: String) in
            text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        }
        let expected = words(reference), got = words(output)
        // Longest common subsequence: reference words with no counterpart.
        var row = [Int](repeating: 0, count: got.count + 1)
        for word in expected {
            var diagonal = 0
            for (column, candidate) in got.enumerated() {
                let above = row[column + 1]
                row[column + 1] = word == candidate ? diagonal + 1 : max(row[column + 1], row[column])
                diagonal = above
            }
        }
        return expected.count - (row.last ?? 0)
    }
}

struct LabError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - One take's numbers

struct TakeRecord: Codable {
    let label: String
    let condition: String
    let take: String
    let index: Int
    let speechSeconds: Double
    let keyDownToListening: Double?
    /// Key-down to the first buffer reaching the capture: speech before it
    /// is speech no take can contain.
    let keyDownToFirstAudio: Double?
    /// Milliseconds after key-down at which each step of the start happened.
    let startPath: StartPath
    let microphoneStartup: Double?
    let releaseToText: Double?
    let releaseToPaste: Double?
    let releaseToRead: Double?
    let releaseToIdle: Double
    let captureFreeze: Double?
    let recognition: Double?
    let engine: Double?
    let queued: Double?
    let streamedSegments: Int?
    let recordedSeconds: Double?
    let landed: Bool
    let wordsMissed: Int?
    let notice: String?
    let deviceCallbacks: Int?
    let deviceFramesLost: Int?
    let deviceLongestCallbackGap: Double?
    let deviceLongestDelivery: Double?
    /// Where in the take's audio the first lost cycle fell.
    let deviceFirstLossAt: Double?
    let mainThreadLongestStall: Double
    let mainThreadStallsOver50: Int
    let mainThreadStallsOver100: Int
    /// When the longest stall began, in milliseconds after key-down.
    let mainThreadLongestStallAt: Double?
    let diskReadBytes: UInt64?
    /// Whether the default input was still running anywhere once the take
    /// was over. A kept microphone must leave it stopped.
    let microphoneRunningAfter: Bool?
    let thermalState: Int
    /// The Mac is shared: the one-minute load average says how much of the
    /// load was ours.
    let loadAverage: Double
}

/// Milliseconds after key-down: when the key-down's own main-thread work
/// returned, when the start lane began and finished opening the device, when
/// the device start began and returned, and when the first buffer arrived.
struct StartPath: Codable {
    let mainThread: Double
    let openBegan: Double?
    let openEnded: Double?
    let startBegan: Double?
    let startEnded: Double?
    let firstBuffer: Double?
}

struct LabSummary {
    let label: String
    let records: [TakeRecord]

    func markdown() -> String {
        var lines = [
            "### \(label)",
            "",
            "| Condition | Take | n | Landed | Release → paste p50 / p95 ms | Release → target read p50 / p95 ms | Key-down → first audio p50 / p95 ms | Engine p50 ms | Words missed | Device frames lost | Main-thread stalls > 100 ms | Longest stall ms |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
        var seen: [String] = []
        for record in records where !seen.contains(record.condition + record.take) {
            seen.append(record.condition + record.take)
            let group = records.filter { $0.condition == record.condition && $0.take == record.take }
            let paste = group.compactMap(\.releaseToPaste), read = group.compactMap(\.releaseToRead)
            let mic = group.compactMap(\.keyDownToFirstAudio), engine = group.compactMap(\.engine)
            lines.append("| \(record.condition) | \(record.take) | \(group.count) | \(group.filter(\.landed).count) "
                + "| \(Self.pair(paste)) | \(Self.pair(read)) | \(Self.pair(mic)) | \(Self.format(Self.percentile(engine, 0.5))) "
                + "| \(group.compactMap(\.wordsMissed).reduce(0, +)) | \(group.compactMap(\.deviceFramesLost).reduce(0, +)) "
                + "| \(group.map(\.mainThreadStallsOver100).reduce(0, +)) | \(Self.format(group.map(\.mainThreadLongestStall).max())) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }

    static func pair(_ values: [Double]) -> String {
        "\(format(percentile(values, 0.5))) / \(format(percentile(values, 0.95)))"
    }

    static func format(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "–"
    }
}

// MARK: - The microphone, with a sentence in place of the room

/// One recorded sentence, ready to stand in for a microphone's samples.
struct SpeechSource: Sendable {
    let samples: [Float]
    let sampleRate: Double

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LabError("cannot read \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw LabError("speech must be float PCM") }
        samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        sampleRate = format.sampleRate
    }

    /// The same speech at another rate, by linear interpolation. Done once per
    /// take, before the microphone starts, never on its audio thread.
    func resampled(to rate: Double) -> [Float] {
        guard rate != sampleRate, !samples.isEmpty else { return samples }
        let count = Int(Double(samples.count) * rate / sampleRate)
        let step = sampleRate / rate
        return (0..<count).map { index in
            let position = Double(index) * step
            let low = min(Int(position), samples.count - 1), high = min(low + 1, samples.count - 1)
            let fraction = Float(position - Double(low))
            return samples[low] + (samples[high] - samples[low]) * fraction
        }
    }
}

/// The real microphone, opened, started and stopped as in a take, whose
/// buffers carry a recorded sentence instead of the room.
///
/// It also watches the device for lost audio: a buffer whose sample time does
/// not follow on from the previous one means frames the device never
/// delivered, and a long wait between buffers means the audio thread itself
/// was late.
final class SpeechOverMicrophone: CaptureInput, @unchecked Sendable {
    struct Counters {
        let callbacks: Int
        let framesLost: Int
        let longestGapMilliseconds: Double
        /// From the device's timestamp on a buffer to the capture's handler
        /// running for it: how late the hand-off off the audio thread was.
        let longestDeliveryMilliseconds: Double
        let firstLossMilliseconds: Double?
    }

    private let microphone: any CaptureInput
    private let speech: SpeechSource
    private let lock = NSLock()
    private var stream: [Float] = []
    private var cursor = 0
    private var scratch: AVAudioPCMBuffer?
    private var callbacks = 0
    private var framesLost = 0
    private var nextSampleTime: Double?
    private var lastHostTime: UInt64?
    private var longestGap: UInt64 = 0
    private var longestDelivery: UInt64 = 0
    /// When the capture got its first buffer, on the mach clock.
    private(set) var firstDelivery: UInt64?
    private var firstSampleTime: Double?
    /// Where the first lost cycle fell, in milliseconds of the take's audio.
    private var firstLoss: Double?

    init(_ microphone: any CaptureInput, speech: SpeechSource) {
        self.microphone = microphone
        self.speech = speech
    }

    var format: AVAudioFormat { microphone.format }
    var handlerMayFollowStart: Bool { microphone.handlerMayFollowStart }

    func install(_ handler: @escaping CaptureHandler, onLost: @escaping @Sendable () -> Void) {
        let format = microphone.format
        stream = speech.resampled(to: format.sampleRate)
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)
        microphone.install({ [self] buffer, time in
            handler(self.substitute(buffer, at: time), time)
        }, onLost: onLost)
    }

    /// Around the device start, on the mach clock.
    private(set) var startBegan: UInt64?
    private(set) var startEnded: UInt64?

    func start() throws {
        startBegan = mach_absolute_time()
        defer { startEnded = mach_absolute_time() }
        try microphone.start()
    }
    func stop() { microphone.stop() }

    func firstAudio() -> UInt64? { lock.withLock { firstDelivery } }

    func counters() -> Counters {
        lock.withLock {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let nanoseconds = Double(longestGap) * Double(timebase.numer) / Double(timebase.denom)
            let delivery = Double(longestDelivery) * Double(timebase.numer) / Double(timebase.denom)
            return Counters(callbacks: callbacks, framesLost: framesLost,
                            longestGapMilliseconds: nanoseconds / 1e6,
                            longestDeliveryMilliseconds: delivery / 1e6,
                            firstLossMilliseconds: firstLoss)
        }
    }

    private func substitute(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> AVAudioPCMBuffer {
        let frames = Int(buffer.frameLength)
        lock.lock()
        callbacks += 1
        if firstDelivery == nil { firstDelivery = mach_absolute_time() }
        if time.isSampleTimeValid {
            if firstSampleTime == nil { firstSampleTime = Double(time.sampleTime) }
            if let expected = nextSampleTime, Double(time.sampleTime) > expected {
                framesLost += Int(Double(time.sampleTime) - expected)
                if firstLoss == nil, let first = firstSampleTime {
                    firstLoss = (expected - first) / buffer.format.sampleRate * 1_000
                }
            }
            nextSampleTime = Double(time.sampleTime) + Double(frames)
        }
        if time.isHostTimeValid {
            if let last = lastHostTime, time.hostTime > last { longestGap = max(longestGap, time.hostTime - last) }
            lastHostTime = time.hostTime
            let now = mach_absolute_time()
            if now > time.hostTime { longestDelivery = max(longestDelivery, now - time.hostTime) }
        }
        let start = cursor
        cursor += frames
        lock.unlock()

        guard let scratch, buffer.format.commonFormat == .pcmFormatFloat32,
              AVAudioFrameCount(frames) <= scratch.frameCapacity else { return buffer }
        scratch.frameLength = buffer.frameLength
        for channelBuffer in UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList) {
            guard let data = channelBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(channelBuffer.mNumberChannels)
            for frame in 0..<frames {
                let index = start + frame
                let sample = index < stream.count ? stream[index] : 0
                for channel in 0..<channels { data[frame * channels + channel] = sample }
            }
        }
        return scratch
    }
}

/// Which sentence the next take speaks, and the microphone it is speaking into.
final class InjectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private var input: SpeechOverMicrophone?
    /// When the start lane began and finished opening the device, on the
    /// mach clock: the boundaries of the take's start path the lab can see.
    private var opening: (began: UInt64, ended: UInt64)?

    func noteOpen(began: UInt64, ended: UInt64) { lock.withLock { opening = (began, ended) } }

    func takeOpening() -> (began: UInt64, ended: UInt64)? {
        lock.withLock { defer { opening = nil }; return opening }
    }

    var takeIndex: Int {
        get { lock.withLock { index } }
        set { lock.withLock { index = newValue } }
    }

    var current: SpeechOverMicrophone? {
        get { lock.withLock { input } }
        set { lock.withLock { input = newValue } }
    }
}

// MARK: - The target application

/// The system edge of the paste. Everything is as in the app except the key:
/// instead of a ⌘V delivered to the window in front, the reader process is
/// told to paste, and it reads the board the way TextEdit does.
final class LabInputSystem: InputSystem, @unchecked Sendable {
    private let target: TargetApplication
    private let reader: PasteReader

    init(target: TargetApplication, reader: PasteReader) {
        self.target = target
        self.reader = reader
    }

    var isSecureInputEnabled: Bool { false }
    var isAccessibilityTrusted: Bool { true }
    func frontmostApplication() -> TargetApplication? { target }
    func heldModifiers() -> CGEventFlags { [] }
    func activate(_ target: TargetApplication) async -> Bool { true }
    func pasteKeyCode() async -> CGKeyCode { CGKeyCode(kVK_ANSI_V) }

    func post(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        if keyCode == CGKeyCode(kVK_ANSI_V), flags.contains(.maskCommand) { reader.paste() }
    }
}

/// A second process that stays running and pastes on request, through
/// NSTextView's own pasteboard read. Never the general pasteboard.
final class PasteReader: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var received: [String] = []
    private var partial = Data()

    init(board name: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", """
            ObjC.import('AppKit');
            const stdin = $.NSFileHandle.fileHandleWithStandardInput;
            const stdout = $.NSFileHandle.fileHandleWithStandardOutput;
            const board = $.NSPasteboard.pasteboardWithName('\(name)');
            for (;;) {
                const request = stdin.availableData;
                if (request.length == 0) break;
                const view = $.NSTextView.alloc.initWithFrame($.NSMakeRect(0, 0, 400, 100));
                view.readSelectionFromPasteboard(board);
                const text = ObjC.unwrap(view.string).replace(/\\n/g, ' ');
                stdout.writeData($(text + '\\n').dataUsingEncoding($.NSUTF8StringEncoding));
            }
            """]
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        try process.run()
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var pastes: [String] { lock.withLock { received } }

    func paste() {
        try? input.fileHandleForWriting.write(contentsOf: Data("paste\n".utf8))
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        lock.withLock {
            partial.append(data)
            while let newline = partial.firstIndex(of: 10) {
                received.append(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
                partial.removeSubrange(partial.startIndex...newline)
            }
        }
    }
}

// MARK: - The HUD's thread

/// Ticks on the main thread every 10 ms. A late tick is time the HUD, the
/// waveform and every main-actor step of the take could not run.
@MainActor
final class MainThreadHeartbeat {
    struct Window {
        let longest: Double
        let over50: Int
        let over100: Int
        let longestAt: Double?
    }

    private var timer: DispatchSourceTimer?
    private var last: ContinuousClock.Instant?
    private var opened: ContinuousClock.Instant?
    private var gaps: [(at: Double, length: Double)] = []

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func beginWindow() {
        gaps = []
        last = nil
        opened = .now
    }

    func endWindow() -> Window {
        let longest = gaps.max { $0.length < $1.length }
        return Window(longest: longest?.length ?? 0,
                      over50: gaps.filter { $0.length > 50 }.count,
                      over100: gaps.filter { $0.length > 100 }.count,
                      longestAt: longest?.at)
    }

    private func tick() {
        let now = ContinuousClock.now
        if let last, let opened {
            gaps.append((at: opened.duration(to: last).ms, length: last.duration(to: now).ms - 10))
        }
        last = now
    }
}

// MARK: - Load

/// The loads, as processes the lab owns and always stops.
final class Stress {
    private var processes: [Process] = []
    private var hogs: [Process] = []

    /// The October 9 load: one busy process per logical CPU, at the default
    /// priority every ordinary app gets.
    func saturateCPU() throws {
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            try launch("/bin/sh", ["-c", "while :; do :; done"])
        }
    }

    /// Real memory pressure: a bounded hog that keeps gigabytes of
    /// incompressible pages hot, so the system has to page everything else
    /// out. `memory_pressure -S` only sets an artificial level and moves no
    /// page, so it cannot reproduce a model read back from swap.
    func pressMemory(hog: URL?, gigabytes: String) throws {
        guard let hog else { throw LabError("memory conditions need STRESS_LAB_HOG") }
        let process = try launch(hog.path, [gigabytes, "3600"], output: Pipe())
        hogs.append(process)
        let ready = DispatchSemaphore(value: 0)
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = { handle in
            if String(decoding: handle.availableData, as: UTF8.self).contains("ready") { ready.signal() }
        }
        guard ready.wait(timeout: .now() + 120) == .success else { throw LabError("the memory hog never got ready") }
    }

    func stopAll() {
        for process in processes where process.isRunning { process.terminate() }
        for process in processes { process.waitUntilExit() }
        processes = []
        hogs = []
    }

    /// Ends the memory hogs and leaves any CPU load running.
    func stopHogs() {
        for process in hogs where process.isRunning { process.terminate() }
        for process in hogs { process.waitUntilExit() }
        processes.removeAll { hogs.contains($0) }
        hogs = []
    }

    @discardableResult
    private func launch(_ path: String, _ arguments: [String], output: Pipe? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        processes.append(process)
        return process
    }
}

// MARK: - Small helpers

private func processDiskReadBytes() -> UInt64? {
    var info = rusage_info_current()
    let succeeded = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) == 0
        }
    }
    return succeeded ? info.ri_diskio_bytesread : nil
}

private func machMilliseconds(from start: UInt64, to end: UInt64) -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = end >= start ? Double(end - start) : -Double(start - end)
    return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

private func defaultInputIsRunning() -> Bool? {
    guard let device = MicrophoneAudioSource.defaultInputDevice() else { return nil }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return nil }
    return running != 0
}

private func loadAverage() -> Double {
    var load = [Double](repeating: 0, count: 3)
    return getloadavg(&load, 3) > 0 ? load[0] : -1
}

private extension Duration {
    var ms: Double { Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15 }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
