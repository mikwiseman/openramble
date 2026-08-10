import Foundation

/// Record audio in WAV during dictation.
///
/// We write to disk, and don’t save it in memory: an hour’s dictation is more than a hundred
/// megabytes, and the file at the same time survives the application crash and allows you to repeat
/// recognition if it fails.
///
/// The WAV header contains dimensions that are only known at the end, so
/// First the blank is written, and upon completion the dimensions are put in place.
public final class WAVWriter: @unchecked Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case cannotCreateFile(String)
        case writeFailed(String)
        case notOpen
    }

    private let url: URL
    private let sampleRate: Int
    private let channels: Int
    private let bitsPerSample = 16

    private var handle: FileHandle?
    private var bytesWritten: Int = 0
    private let lock = NSLock()

    public init(url: URL, sampleRate: Int = 16_000, channels: Int = 1) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var fileURL: URL { url }

    /// Duration of what has been recorded so far.
    public var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let bytesPerFrame = channels * bitsPerSample / 8
        guard bytesPerFrame > 0, sampleRate > 0 else { return 0 }
        return Double(bytesWritten / bytesPerFrame) / Double(sampleRate)
    }

    /// Create a file and write a header template.
    public func open() throws {
        lock.lock()
        defer { lock.unlock() }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard FileManager.default.createFile(atPath: url.path, contents: header(dataBytes: 0)) else {
            throw Failure.cannotCreateFile(url.path)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            self.handle = handle
            bytesWritten = 0
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Add a portion of sound.
    ///
    /// Input - Float32 in the range [-1, 1], 16-bit PCM goes to disk:
    /// twice as compact and exactly what recognition expects.
    public func append(_ samples: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw Failure.notOpen }

        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Close the file, putting the actual dimensions in the title.
    @discardableResult
    public func close() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw Failure.notOpen }
        // The handle is freed anyway. Otherwise unsuccessful closing
        // would leave the file open forever: writer is unavailable after this, and
        // there is no one else to close it - this is how the limit is reached in a day of dictation
        // open process files.
        defer { self.handle = nil }

        do {
            try handle.synchronize()
            // The dimensions are known only now - we rewrite the entire title.
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(dataBytes: bytesWritten))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw Failure.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// Abort recording and delete file - the user canceled the dictation.
    public func discard() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// 44 byte WAV header.
    private func header(dataBytes: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1) // PCM without compression
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))

        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(dataBytes))
        return data
    }
}
