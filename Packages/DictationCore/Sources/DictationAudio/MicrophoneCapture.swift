import AVFoundation
import DictationCore
import Foundation
import os

/// Запись с микрофона в файл.
///
/// Движок поднимается в момент нажатия клавиши и глушится сразу после записи:
/// от этого зависит обещание «индикатор записи не горит, пока мы не слушаем».
/// Плата за это — задержка холодного старта, поэтому запуск сделан максимально
/// коротким, а звук подтверждения играет только после первого пришедшего кадра.
public actor MicrophoneCapture: AudioCapturing {
    private let logger = Logger(subsystem: "is.waiwai.dictation", category: "capture")

    /// Куда складывать записи.
    private let directory: URL
    private let sampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var writer: WAVWriter?
    private var converter: AVAudioConverter?
    private var writeFailure: (any Error)?

    /// Время прихода первого кадра — по нему меряется задержка старта.
    private var firstBufferAt: ContinuousClock.Instant?
    private var startedAt: ContinuousClock.Instant?

    public init(directory: URL) {
        self.directory = directory
    }

    /// Сколько прошло от запуска движка до первого реального кадра звука.
    ///
    /// Это и есть та величина, из-за которой срезается первое слово.
    public var startupLatency: Duration? {
        guard let startedAt, let firstBufferAt else { return nil }
        return startedAt.duration(to: firstBufferAt)
    }

    public func startRecording() async throws -> URL {
        guard engine == nil else { throw AudioCaptureError.engineUnavailable("запись уже идёт") }

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
            throw AudioCaptureError.engineUnavailable("микрофон недоступен")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            writer.discard()
            self.writer = nil
            throw AudioCaptureError.engineUnavailable("не построился формат записи")
        }

        // Ресемплинг нужен почти всегда: встроенный микрофон отдаёт 44,1 или 48 кГц,
        // а распознавание ждёт 16 кГц.
        converter = inputFormat.sampleRate == sampleRate && inputFormat.channelCount == 1
            ? nil
            : AVAudioConverter(from: inputFormat, to: targetFormat)

        let converter = self.converter
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            // Колбэк приходит на потоке звукового движка — уносим данные в актор
            // как обычный массив, а не как буфер, который нельзя передавать между
            // изоляциями.
            let samples = Self.extractSamples(from: buffer, using: converter, target: targetFormat)
            guard !samples.isEmpty else { return }
            Task { [weak self] in
                await self?.consume(samples)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            writer.discard()
            self.writer = nil
            self.converter = nil
            throw AudioCaptureError.engineUnavailable(error.localizedDescription)
        }

        self.engine = engine
        return url
    }

    private func consume(_ samples: [Float]) {
        if firstBufferAt == nil { firstBufferAt = .now }
        guard let writer, writeFailure == nil else { return }
        do {
            try writer.append(samples)
        } catch {
            // Диск кончился или файл недоступен — запись дальше бессмысленна,
            // но остановку инициирует владелец, а не колбэк звукового потока.
            writeFailure = error
            logger.error("Запись прервана: \(String(describing: error), privacy: .public)")
        }
    }

    public func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        guard let engine, let writer else { throw AudioCaptureError.notRecording }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.converter = nil

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
            throw AudioCaptureError.writeFailed(String(describing: error))
        }
        self.writer = nil
        return (url, duration)
    }

    public func abortRecording() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        writer?.discard()
        writer = nil
    }

    /// Привести пришедший кадр к моно 16 кГц.
    private nonisolated static func extractSamples(
        from buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        target: AVAudioFormat
    ) -> [Float] {
        guard let converter else {
            guard let channel = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
