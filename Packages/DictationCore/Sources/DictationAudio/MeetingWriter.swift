import DictationCore
import Foundation

/// The recording on disk: one stereo WAV and its waveform, growing together.
///
/// `WAVWriter` needs no change for this. It is already channel-parameterised
/// and writes a flat Int16 stream, so interleaved `[L0, R0, L1, R1, …]` with
/// `channels: 2` is correct as written — and interleaving is what makes the
/// two sides sample-locked by the file format itself. A three-sample skew
/// between channels cannot exist in an interleaved WAV.
///
/// One failure latches everything. A writer that keeps accepting audio after
/// a write failed would let the UI say "Recording" over a dead file; the
/// caller sees `hasWriteFailure` and stops honestly instead.
public final class MeetingWriter: @unchecked Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case mismatchedChannels(microphone: Int, system: Int)
        case writeFailed(String)
        case notOpen
    }

    public static let audioFileName = "audio.wav"
    public static let peaksFileName = "peaks.bin"
    public static let sampleRate = 16_000

    public let audioURL: URL
    public let peaksURL: URL

    private let wav: WAVWriter
    private let peaks: PeakFile
    private let lock = NSLock()
    private var bucket: (microphone: Float, system: Float, filled: Int) = (0, 0, 0)
    private var framesWritten = 0
    private var failed = false

    public init(directory: URL) {
        audioURL = directory.appending(path: Self.audioFileName, directoryHint: .notDirectory)
        peaksURL = directory.appending(path: Self.peaksFileName, directoryHint: .notDirectory)
        wav = WAVWriter(url: audioURL, sampleRate: Self.sampleRate, channels: 2)
        peaks = PeakFile(url: peaksURL, channelCount: 2)
    }

    public var hasWriteFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    /// Frames on disk so far — the recording's own clock.
    public var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return framesWritten
    }

    public var duration: TimeInterval { Double(frameCount) / Double(Self.sampleRate) }

    public func open() throws {
        do {
            try wav.open()
            try peaks.open()
        } catch {
            throw Failure.writeFailed(String(describing: error))
        }
    }

    /// Append one stretch of both channels. The two must be the same length:
    /// the aligner guarantees it, and anything else would put the channels
    /// out of step for the rest of the file.
    public func append(microphone: [Float], system: [Float]) throws {
        guard microphone.count == system.count else {
            throw Failure.mismatchedChannels(microphone: microphone.count, system: system.count)
        }
        guard !microphone.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { throw Failure.writeFailed("a previous write failed") }

        var interleaved = [Float]()
        interleaved.reserveCapacity(microphone.count * 2)
        for i in 0..<microphone.count {
            interleaved.append(microphone[i])
            interleaved.append(system[i])
        }
        do {
            try wav.append(interleaved)
            framesWritten += microphone.count
            try accumulatePeaks(microphone: microphone, system: system)
        } catch {
            failed = true
            throw Failure.writeFailed(String(describing: error))
        }
    }

    /// Seal, make durable, close — the recording ended normally.
    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            if bucket.filled > 0 {
                try peaks.append([bucket.microphone, bucket.system])
                bucket = (0, 0, 0)
            }
            try peaks.close()
            try wav.close()
        } catch {
            failed = true
            throw Failure.writeFailed(String(describing: error))
        }
    }

    /// Drop the descriptors without sealing — the shape a crash leaves. What
    /// reached disk stays; `repairHeader(at:)` makes it playable again.
    public func abandon() {
        lock.lock()
        defer { lock.unlock() }
        wav.abandonForRecovery()
        peaks.abandon()
    }

    private func accumulatePeaks(microphone: [Float], system: [Float]) throws {
        let size = peaks.framesPerBucket
        for i in 0..<microphone.count {
            bucket.microphone = max(bucket.microphone, abs(microphone[i]))
            bucket.system = max(bucket.system, abs(system[i]))
            bucket.filled += 1
            if bucket.filled == size {
                try peaks.append([bucket.microphone, bucket.system])
                bucket = (0, 0, 0)
            }
        }
    }

    // MARK: - Recovery

    private static let headerBytes = 44
    private static let bytesPerFrame = 4

    /// Rewrite the RIFF and data sizes from the file's actual length.
    ///
    /// A WAV that was being written when the process died has a header that
    /// still says zero bytes of audio, and every player believes it. The
    /// audio is all there after the header; only the two size fields lie.
    /// Returns the frame count the file now declares.
    @discardableResult
    public static func repairHeader(at url: URL) throws -> Int {
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        defer { try? handle.close() }
        do {
            let head = try handle.read(upToCount: headerBytes) ?? Data()
            guard head.count == headerBytes,
                  head[0..<4] == Data("RIFF".utf8),
                  head[8..<12] == Data("WAVE".utf8),
                  head[36..<40] == Data("data".utf8) else {
                throw Failure.writeFailed("not a WAV this app wrote")
            }
            let total = Int(try handle.seekToEnd())
            let dataBytes = max(0, total - headerBytes) / bytesPerFrame * bytesPerFrame
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: UInt32(36 + dataBytes).littleEndianData)
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: UInt32(dataBytes).littleEndianData)
            try handle.synchronize()
            return dataBytes / bytesPerFrame
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Frames in a finished or repaired file, from its size.
    public static func frameCount(at url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return max(0, size - headerBytes) / bytesPerFrame
    }
}

extension UInt32 {
    fileprivate var littleEndianData: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}
