import AVFoundation
import Foundation

/// Converts file audio to mono 16 kHz Float32. The cursor retains converter
/// state across reads, including the resampler's final buffered samples.
public struct AudioFileReader: Sendable {
    public static let targetSampleRate: Double = 16_000
    public init() {}

    public enum Failure: Error, Sendable, Equatable {
        case unreadable(String)
        case emptyFile
        case durationExceeded(actual: TimeInterval, maximum: TimeInterval)
        case conversionFailed(String)
    }

    public func samples(from url: URL, maximumDuration: TimeInterval? = nil) throws -> [Float] {
        try Task.checkCancellation()
        let cursor = try Cursor(url: url, maximumDuration: maximumDuration)
        var result: [Float] = []
        while true {
            try Task.checkCancellation()
            let chunk = try cursor.read(frames: 16_384)
            if chunk.isEmpty { return result }
            result.append(contentsOf: chunk)
        }
    }

    /// Either local to one synchronous call or owned by AudioFileStream and
    /// accessed exclusively on LocalTranscriber's serial disk queue.
    final class Cursor: @unchecked Sendable {
        let duration: TimeInterval
        private let file: AVAudioFile
        private let outputFormat: AVAudioFormat
        private let converter: AVAudioConverter?
        private let input: AVAudioPCMBuffer
        private var ended = false
        private var readError: Error?

        init(url: URL, maximumDuration: TimeInterval? = nil) throws {
            do { file = try AVAudioFile(forReading: url) }
            catch { throw Failure.unreadable(error.localizedDescription) }
            guard file.length > 0 else { throw Failure.emptyFile }
            let source = file.processingFormat
            guard source.sampleRate > 0 else { throw Failure.conversionFailed("invalid sample rate") }
            duration = Double(file.length) / source.sampleRate
            if let maximumDuration, duration > maximumDuration {
                throw Failure.durationExceeded(actual: duration, maximum: maximumDuration)
            }
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate, channels: 1, interleaved: false),
                  let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 16_384) else {
                throw Failure.conversionFailed("couldn't allocate conversion buffers")
            }
            self.input = input
            outputFormat = target
            if source == target {
                converter = nil
            } else {
                guard let converter = AVAudioConverter(from: source, to: target) else {
                    throw Failure.conversionFailed("couldn't create an audio converter")
                }
                // The default remaps channel zero; it does not mix stereo.
                // Meeting files can carry the other speaker only on the right.
                converter.downmix = true
                self.converter = converter
            }
        }

        func read(frames: Int) throws -> [Float] {
            guard frames > 0, frames <= Int(UInt32.max) else {
                throw Failure.conversionFailed("invalid read size")
            }
            if ended { return [] }
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)) else {
                throw Failure.conversionFailed("couldn't allocate the read buffer")
            }
            if let converter {
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { [self] requested, state in
                    guard file.framePosition < file.length else {
                        state.pointee = .endOfStream
                        return nil
                    }
                    do {
                        let count = min(AVAudioFrameCount(requested), input.frameCapacity,
                                        AVAudioFrameCount(min(file.length - file.framePosition, Int64(UInt32.max))))
                        try file.read(into: input, frameCount: count)
                        state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                        return input.frameLength == 0 ? nil : input
                    } catch {
                        readError = error
                        state.pointee = .endOfStream
                        return nil
                    }
                }
                if let readError { throw Failure.unreadable(readError.localizedDescription) }
                if let error { throw Failure.conversionFailed(error.localizedDescription) }
                guard status != .error else { throw Failure.conversionFailed("audio conversion failed") }
                ended = status == .endOfStream
            } else {
                if file.framePosition >= file.length { ended = true; return [] }
                do { try file.read(into: output, frameCount: AVAudioFrameCount(min(Int64(frames), file.length - file.framePosition))) }
                catch { throw Failure.unreadable(error.localizedDescription) }
            }
            guard let channel = output.floatChannelData?[0] else {
                throw Failure.conversionFailed("no channel data")
            }
            return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
    }
}

/// Bounded reads on a disk queue, independently of the inference queue. One
/// pending read can prepare the next batch while the current batch computes.
public final class AudioFileStream: Sendable {
    public let duration: TimeInterval
    private let cursor: AudioFileReader.Cursor

    public init(url: URL) async throws {
        let cursor = try await LocalTranscriber.onDisk { try AudioFileReader.Cursor(url: url) }
        self.cursor = cursor
        duration = cursor.duration
    }

    public func read(frames: Int = 16_384) async throws -> [Float] {
        try Task.checkCancellation()
        let cursor = cursor
        let result = try await LocalTranscriber.onDisk { try cursor.read(frames: frames) }
        try Task.checkCancellation()
        return result
    }
}
