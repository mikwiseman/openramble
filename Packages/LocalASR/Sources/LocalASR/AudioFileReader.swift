import DictationCore
import AVFoundation
import Foundation

/// Reading an audio file into the format that awaits recognition:
/// mono, 16 kHz, Float32.
///
/// The recording of the dictation goes to disk, and is not kept in memory: an hour-long dictation is
/// more than a hundred megabytes, and the file on the disk also provides recovery after a failure
/// and repeat if there is a recognition error.
public struct AudioFileReader: Sendable {
    /// The frequency at which Parakeet operates.
    public static let targetSampleRate: Double = 16_000

    public init() {}

    public enum Failure: Error, Sendable, Equatable {
        case unreadable(String)
        case emptyFile
        case conversionFailed(String)
    }

    /// Read the entire file, resulting in 16 kHz mono.
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
            throw Failure.conversionFailed("couldn't create the target format")
        }

        // If the file is already in the required format, no conversion is needed.
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
            throw Failure.conversionFailed("couldn't allocate the read buffer")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard let channel = buffer.floatChannelData?[0] else {
            throw Failure.conversionFailed("no channel data")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func readConverted(
        file: AVAudioFile,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) throws -> [Float] {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw Failure.conversionFailed("couldn't create a converter \(sourceFormat) → \(targetFormat)")
        }

        var output: [Float] = []
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        output.reserveCapacity(Int(Double(file.length) * ratio) + 1024)

        let chunkFrames: AVAudioFrameCount = 16_384
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
            throw Failure.conversionFailed("couldn't allocate the input buffer")
        }
        let outputCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw Failure.conversionFailed("couldn't allocate the output buffer")
        }

        var reachedEnd = false
        while !reachedEnd {
            inputBuffer.frameLength = 0
            // You can only read as long as there is something to read: beyond the end of the file
            // AVAudioFile throws an error rather than returning zero frames.
            if file.framePosition < file.length {
                do {
                    try file.read(into: inputBuffer, frameCount: chunkFrames)
                } catch {
                    throw Failure.unreadable(error.localizedDescription)
                }
            }
            if inputBuffer.frameLength == 0 { reachedEnd = true }

            // Closure is marked as parallel, but is called synchronously
            // here - the boxes are needed only to explain this to the compiler.
            let supplied = UncheckedBox(false)
            let input = UncheckedBox(inputBuffer)
            let atEnd = reachedEnd
            var conversionError: NSError?
            outputBuffer.frameLength = 0

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
                // The converter asks for data in chunks; We give away each input buffer
                // exactly once, otherwise it will loop on it.
                if supplied.value || input.value.frameLength == 0 {
                    statusPointer.pointee = atEnd ? .endOfStream : .noDataNow
                    return nil
                }
                supplied.value = true
                statusPointer.pointee = .haveData
                return input.value
            }

            if let conversionError {
                throw Failure.conversionFailed(conversionError.localizedDescription)
            }
            if status == .error {
                throw Failure.conversionFailed("the converter returned an error")
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
