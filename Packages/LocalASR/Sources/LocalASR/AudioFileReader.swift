import AVFoundation
import Foundation

/// Чтение звукового файла в тот формат, который ждёт распознавание:
/// моно, 16 кГц, Float32.
///
/// Запись диктовки идёт на диск, а не держится в памяти: часовая диктовка — это
/// больше сотни мегабайт, и файл на диске заодно даёт восстановление после сбоя
/// и повтор при ошибке распознавания.
public struct AudioFileReader: Sendable {
    /// Частота, на которой работает Parakeet.
    public static let targetSampleRate: Double = 16_000

    public init() {}

    public enum Failure: Error, Sendable, Equatable {
        case unreadable(String)
        case emptyFile
        case conversionFailed(String)
    }

    /// Прочитать файл целиком, приведя к моно 16 кГц.
    public func samples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }

        guard file.length > 0 else { throw Failure.emptyFile }

        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw Failure.conversionFailed("не построился целевой формат")
        }

        // Если файл уже в нужном формате, конвертация не нужна.
        if sourceFormat.sampleRate == Self.targetSampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            return try readDirect(file: file, format: sourceFormat)
        }

        return try readConverted(file: file, from: sourceFormat, to: targetFormat)
    }

    private func readDirect(file: AVAudioFile, format: AVAudioFormat) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw Failure.conversionFailed("не выделился буфер чтения")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard let channel = buffer.floatChannelData?[0] else {
            throw Failure.conversionFailed("нет данных канала")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func readConverted(
        file: AVAudioFile,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) throws -> [Float] {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw Failure.conversionFailed("не создался конвертер \(sourceFormat) → \(targetFormat)")
        }

        var output: [Float] = []
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        output.reserveCapacity(Int(Double(file.length) * ratio) + 1024)

        let chunkFrames: AVAudioFrameCount = 16_384
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
            throw Failure.conversionFailed("не выделился входной буфер")
        }
        let outputCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw Failure.conversionFailed("не выделился выходной буфер")
        }

        var reachedEnd = false
        while !reachedEnd {
            inputBuffer.frameLength = 0
            // Читать можно только пока есть что читать: за концом файла
            // AVAudioFile бросает ошибку, а не возвращает ноль кадров.
            if file.framePosition < file.length {
                do {
                    try file.read(into: inputBuffer, frameCount: chunkFrames)
                } catch {
                    throw Failure.unreadable(error.localizedDescription)
                }
            }
            if inputBuffer.frameLength == 0 { reachedEnd = true }

            var suppliedThisRound = false
            var conversionError: NSError?
            outputBuffer.frameLength = 0

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
                // Конвертер просит данные по кускам; каждый входной буфер отдаём
                // ровно один раз, иначе он зациклится на нём.
                if suppliedThisRound || inputBuffer.frameLength == 0 {
                    statusPointer.pointee = reachedEnd ? .endOfStream : .noDataNow
                    return nil
                }
                suppliedThisRound = true
                statusPointer.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw Failure.conversionFailed(conversionError.localizedDescription)
            }
            if status == .error {
                throw Failure.conversionFailed("конвертер вернул ошибку")
            }

            if outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] {
                output.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))
                )
            }
            if status == .endOfStream { break }
        }

        guard !output.isEmpty else { throw Failure.emptyFile }
        return output
    }
}
