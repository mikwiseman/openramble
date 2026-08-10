import AVFoundation
import DictationCore
import Foundation
import os

/// Record from a microphone to a file.
///
/// The engine rises at the moment the key is pressed and turns off immediately after recording:
/// the promise “the recording indicator is off while we are not listening” depends on this.
/// The price for this is a delay in the cold start, so the start is done as much as possible
/// short, and the confirmation sound plays only after the first frame arrived.
public actor MicrophoneCapture: AudioCapturing {
    public typealias ConverterFactory = @Sendable (AVAudioFormat, AVAudioFormat) -> AVAudioConverter?
    private let logger = Logger(subsystem: "is.waiwai.dictation", category: "capture")

    /// Where to put the records.
    private let directory: URL
    private let sampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var writer: WAVWriter?
    private var converter: AVAudioConverter?
    private var writeFailure: (any Error)?

    /// The queue of frames between the audio stream and recording to disk.
    private let sink = FrameSink()
    private var isStopping = false

    /// Arrival time of the first frame - the start delay is measured using it.
    private var firstBufferAt: ContinuousClock.Instant?
    private var startedAt: ContinuousClock.Instant?

    /// Waiting for the first frame - `waitForFirstFrame()` answers them.
    ///
    /// Everyone awakens exactly once: either by an incoming frame or by the end
    /// records. There is no second source of awakening on purpose - forgotten here
    /// the continuation would freeze the start of the dictation.
    private var firstFrameWaiters: [CheckedContinuation<Bool, Never>] = []

    /// The recording broke right during the speech.
    ///
    /// You can’t remain silent until it stops: the disk space has run out, otherwise
    /// will be discovered after five minutes of speaking - and there will be no more text.
    private let onFailure: @Sendable (AudioCaptureError) -> Void
    /// Live samples listener - for recognition preview.
    ///
    /// Called after conversion to the target format, already outside the audio stream, including
    /// the same order in which the samples go to WAV. The file remains the source
    /// truths: the listener does not decide anything, he only watches.
    private let onSamples: @Sendable ([Float]) -> Void
    private let converterFactory: ConverterFactory

    public init(
        directory: URL,
        onFailure: @escaping @Sendable (AudioCaptureError) -> Void = { _ in },
        onSamples: @escaping @Sendable ([Float]) -> Void = { _ in },
        converterFactory: @escaping ConverterFactory = { AVAudioConverter(from: $0, to: $1) }
    ) {
        self.directory = directory
        self.onFailure = onFailure
        self.onSamples = onSamples
        self.converterFactory = converterFactory
    }

    /// How long it took from starting the engine to the first real frame of sound.
    ///
    /// This is the value due to which the first word is cut off. Meaning
    /// was considered from the very beginning, but no one read it: it comes out
    /// via `AudioCapturing`, and only now it has a consumer.
    ///
    /// `stopRecording` does not reset these marks - only a new one resets them
    /// `startRecording`, so reading after stopping is legal.
    public func startupLatency() async -> Duration? {
        guard let startedAt, let firstBufferAt else { return nil }
        return startedAt.duration(to: firstBufferAt)
    }

    /// The first frame has already arrived - or it won’t happen.
    ///
    /// It's safe to wait: the continuation is registered and the actor is released, so
    /// stopping and interrupting the recording goes through and wakes up those waiting.
    public func waitForFirstFrame() async -> Bool {
        if firstBufferAt != nil { return true }
        guard engine != nil else { return false }
        return await withCheckedContinuation { continuation in
            firstFrameWaiters.append(continuation)
        }
    }

    private func wakeFirstFrameWaiters(arrived: Bool) {
        guard !firstFrameWaiters.isEmpty else { return }
        let waiting = firstFrameWaiters
        firstFrameWaiters = []
        for waiter in waiting { waiter.resume(returning: arrived) }
    }

    public func startRecording() async throws -> URL {
        guard engine == nil else { throw AudioCaptureError.engineUnavailable("recording is already in progress") }

        // Those waiting for the last entry (if there are any left) will no longer wait for it
        // frame: their recording has ended.
        wakeFirstFrameWaiters(arrived: false)
        startedAt = .now
        firstBufferAt = nil
        writeFailure = nil

        let url = directory.appending(
            path: "take-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).wav",
            directoryHint: .notDirectory
        )
        let writer = WAVWriter(url: url, sampleRate: Int(sampleRate), channels: 1)
        do {
            try writer.open()
        } catch {
            throw AudioCaptureError.writeFailed(String(describing: error))
        }
        self.writer = writer

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            writer.discard()
            self.writer = nil
            throw AudioCaptureError.engineUnavailable("microphone unavailable")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            writer.discard()
            self.writer = nil
            throw AudioCaptureError.engineUnavailable("couldn't create the recording format")
        }

        // Resampling is almost always needed: the built-in microphone outputs 44.1 or 48 kHz,
        // and recognition waits for 16 kHz.
        do {
            self.converter = try Self.converter(
                from: inputFormat,
                to: targetFormat,
                factory: converterFactory
            )
        } catch {
            writer.discard()
            self.writer = nil
            throw error
        }

        let enqueue = await sink.start { [weak self] samples in
            await self?.consume(samples)
        }

        let converter = self.converter
        let failureHandler = onFailure
        let conversionFailure = FailureOnce()
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            // The callback comes on the sound engine thread - we put the data into the queue
            // as a regular array, and not as a buffer that cannot be passed between
            // isolations. We place them synchronously: the queue is the guarantee of order.
            do {
                let samples = try Self.extractSamples(from: buffer, using: converter, target: targetFormat)
                guard !samples.isEmpty else { return }
                enqueue(samples)
            } catch {
                conversionFailure.run {
                    failureHandler(
                        .unsupportedAudioFormat(
                            "audio conversion failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            await sink.cancel()
            writer.discard()
            self.writer = nil
            self.converter = nil
            throw AudioCaptureError.engineUnavailable(error.localizedDescription)
        }

        self.engine = engine
        return url
    }

    private func consume(_ samples: [Float]) {
        if firstBufferAt == nil {
            firstBufferAt = .now
            // Only now the microphone actually hears: before this line the sound
            // confirmation would fool the person by a tenth of a second, and
            // the first word would disappear into silence.
            wakeFirstFrameWaiters(arrived: true)
        }
        onSamples(samples)
        guard let writer, writeFailure == nil else { return }
        do {
            try writer.append(samples)
        } catch {
            // The disk has run out or the file is inaccessible - further recording is pointless.
            // The owner stops the dictation, but he must know about it
            // now, and not when the person finishes.
            writeFailure = error
            logger.error("Recording interrupted: \(String(describing: error), privacy: .public)")
            onFailure(.writeFailed(String(describing: error)))
        }
    }

    public func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        guard let engine, writer != nil, !isStopping else { throw AudioCaptureError.notRecording }
        isStopping = true
        defer { isStopping = false }
        // You can no longer wait for the frame: the recording ends. Otherwise, start the session,
        // hanging on a silent device, would never let go.
        wakeFirstFrameWaiters(arrived: false)

        // First we turn off the engine, then we remove the tap: the frame has already left
        // hardware, manages to get to the queue.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.converter = nil

        // The tail of the record is added here. Without waiting, the file would close earlier
        // last frames - the last word would disappear from the phrase, namely at
        // the person is talking and releases the key.
        await sink.finish()

        guard let writer else { throw AudioCaptureError.notRecording }

        if let writeFailure {
            writer.discard()
            self.writer = nil
            throw AudioCaptureError.writeFailed(String(describing: writeFailure))
        }

        let duration = writer.duration
        let url: URL
        do {
            url = try writer.close()
        } catch {
            self.writer = nil
            throw AudioCaptureError.writeFailed(String(describing: error))
        }
        self.writer = nil
        return (url, duration)
    }

    public func abortRecording() async {
        wakeFirstFrameWaiters(arrived: false)
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        converter = nil
        await sink.cancel()
        writer?.discard()
        writer = nil
    }

    /// Convert the incoming frame to 16 kHz mono.
    nonisolated static func extractSamples(
        from buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        target: AVAudioFormat
    ) throws -> [Float] {
        guard let converter else {
            guard let channel = buffer.floatChannelData?[0] else {
                throw AudioCaptureError.unsupportedAudioFormat("the microphone didn't provide Float32 PCM")
            }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioCaptureError.unsupportedAudioFormat("couldn't create a 16 kHz mono buffer")
        }

        // Boxes explain to the compiler what is factually true: closure
        // executed synchronously here, and not in another thread.
        let supplied = UncheckedBox(false)
        let input = UncheckedBox(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied.value {
                status.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            status.pointee = .haveData
            return input.value
        }

        if let error {
            throw AudioCaptureError.unsupportedAudioFormat(error.localizedDescription)
        }
        guard status != .error else {
            throw AudioCaptureError.unsupportedAudioFormat("the converter rejected an audio frame")
        }
        guard let channel = output.floatChannelData?[0] else {
            throw AudioCaptureError.unsupportedAudioFormat("the converter didn't return Float32 PCM")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Pure seam to check critical fork: `nil` is only allowed
    /// when no conversion is really needed.
    nonisolated static func converter(
        from source: AVAudioFormat,
        to target: AVAudioFormat,
        factory: ConverterFactory
    ) throws -> AVAudioConverter? {
        let needsConversion = source.sampleRate != target.sampleRate
            || source.channelCount != target.channelCount
        guard needsConversion else { return nil }
        guard let converter = factory(source, target) else {
            throw AudioCaptureError.unsupportedAudioFormat(
                "couldn't convert \(Int(source.sampleRate)) Hz / \(source.channelCount) ch to 16 kHz mono"
            )
        }
        return converter
    }
}

/// An audio stream can send several frames before stopping asynchronously.
/// One reason should not create dozens of parallel interrupt tasks.
private final class FailureOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        body()
    }
}
