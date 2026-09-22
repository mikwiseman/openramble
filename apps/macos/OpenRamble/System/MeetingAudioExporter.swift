import AVFoundation
import Foundation

/// The audio a person actually sends someone.
///
/// A recording is stored as 16 kHz stereo PCM because that is what the
/// recogniser reads and what keeps the two sides separable; two hours of it
/// is about 460 MB, which no mail client will take. The same two hours as
/// AAC at 32 kbps is about 29 MB. Listening mixes both sources to mono so
/// either voice plays in both ears; only the original keeps them separate.
///
/// `AVAudioFile` is the whole implementation: it is the sanctioned way to
/// read and write audio here, and `AVAssetExportSession` needs an `AVAsset`,
/// which the network gate forbids for good reasons.
enum MeetingAudioExporter {
    enum Failure: LocalizedError {
        case unreadable(String)
        case unwritable(String)
        case formatMismatch
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): "The recording could not be read. \(detail)"
            case .unwritable(let detail): "The audio file could not be written. \(detail)"
            case .formatMismatch: "The recording is in an unexpected format."
            case .cancelled: "The export was cancelled."
            }
        }
    }

    static let bitRate = 32_000
    /// The on-disk archive keeps both channels but uses AAC instead of raw
    /// PCM. At 96 kbps it is roughly one sixth the size of the WAV while
    /// remaining transparent for speech and meeting playback.
    static let archiveBitRate = 96_000
    /// A quarter second at a time: small enough to notice a cancellation,
    /// large enough that the encoder is never the thing waiting.
    static let chunkFrames: AVAudioFrameCount = 4_096

    /// Encode `source` to AAC in an m4a container at `destination`.
    ///
    /// Blocking, and meant to be called off the main actor. A cancelled or
    /// failed export leaves nothing behind: a half-written m4a that plays
    /// for ten minutes of a two-hour meeting is worse than no file.
    static func export(
        from source: URL,
        to destination: URL,
        isCancelled: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
        let format = input.processingFormat
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunkFrames) else {
            throw Failure.formatMismatch
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]

        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings)
        } catch {
            throw Failure.unwritable(String(describing: error))
        }
        guard output.processingFormat.sampleRate == format.sampleRate,
              output.processingFormat.channelCount == 1 else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.formatMismatch
        }

        let total = max(input.length, 1)
        do {
            while input.framePosition < input.length {
                if isCancelled() { throw Failure.cancelled }
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                guard let channels = buffer.floatChannelData, let samples = mixed.floatChannelData?[0] else {
                    throw Failure.formatMismatch
                }
                mixed.frameLength = buffer.frameLength
                // Average, not sum: simultaneous voices must not clip.
                let gain = 1 / Float(format.channelCount)
                for frame in 0..<Int(buffer.frameLength) {
                    var sum: Float = 0
                    for channel in 0..<Int(format.channelCount) { sum += channels[channel][frame] }
                    samples[frame] = sum * gain
                }
                try output.write(from: mixed)
                progress(Double(input.framePosition) / Double(total))
            }
        } catch let failure as Failure {
            try? FileManager.default.removeItem(at: destination)
            throw failure
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.unwritable(String(describing: error))
        }
        progress(1)
    }

    /// Compact a completed local recording without touching the WAV until the
    /// new file has closed successfully. The original remains available while
    /// transcription is live; this is only an archive operation after the
    /// transcript is safely on disk.
    static func archive(
        from source: URL,
        to destination: URL,
        isCancelled: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw Failure.formatMismatch
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: archiveBitRate,
        ]
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings)
        } catch {
            throw Failure.unwritable(String(describing: error))
        }
        guard output.processingFormat.sampleRate == format.sampleRate,
              output.processingFormat.channelCount == format.channelCount else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.formatMismatch
        }

        let total = max(input.length, 1)
        do {
            while input.framePosition < input.length {
                if isCancelled() { throw Failure.cancelled }
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                progress(Double(input.framePosition) / Double(total))
            }
        } catch let failure as Failure {
            try? FileManager.default.removeItem(at: destination)
            throw failure
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.unwritable(String(describing: error))
        }
        progress(1)
    }
}
