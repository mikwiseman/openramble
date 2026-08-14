import Darwin
import DictationCore
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
    public typealias Synchronizer = @Sendable (FileHandle) throws -> Void
    public typealias DataWriter = @Sendable (FileHandle, Data) throws -> Void

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
    private var isSealed = false
    private let lock = NSLock()
    private let synchronizer: Synchronizer
    private let dataWriter: DataWriter

    public init(
        url: URL,
        sampleRate: Int = 16_000,
        channels: Int = 1,
        synchronizer: @escaping Synchronizer = { try $0.synchronize() },
        dataWriter: @escaping DataWriter = { try $0.write(contentsOf: $1) }
    ) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.synchronizer = synchronizer
        self.dataWriter = dataWriter
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
        guard handle == nil else { throw Failure.notOpen }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw Failure.cannotCreateFile(url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try RecordingFileLease.acquireExclusive(on: handle)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: header(dataBytes: 0))
            try handle.seekToEnd()
            self.handle = handle
            bytesWritten = 0
            isSealed = false
        } catch {
            try? handle.close()
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
        guard let handle, !isSealed else { throw Failure.notOpen }

        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            // A damaged device/graph can surface non-finite Float32 values.
            // Converting NaN or infinity directly to Int16 traps the process;
            // keep the WAV structurally honest and bound the impulse instead.
            let finite: Float
            if sample.isNaN {
                finite = 0
            } else if sample == .infinity {
                finite = 1
            } else if sample == -.infinity {
                finite = -1
            } else {
                finite = sample
            }
            let clamped = max(-1, min(1, finite))
            let value = Int16(clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        do {
            try dataWriter(handle, data)
            bytesWritten += data.count
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Publish the final WAV header without waiting for durable storage.
    ///
    /// All payload frames must already have been drained. Once this returns,
    /// a decoder can open the file while `synchronizeAndClose()` proceeds on a
    /// background task. One later fsync covers both payload and header.
    @discardableResult
    public func sealForReading() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw Failure.notOpen }
        if isSealed { return url }

        do {
            try sealLocked(handle)
        } catch {
            try? handle.close()
            self.handle = nil
            isSealed = false
            throw Failure.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// Make an already sealed WAV durable and release its descriptor.
    public func synchronizeAndClose() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, isSealed else { throw Failure.notOpen }
        defer {
            self.handle = nil
            isSealed = false
        }

        do {
            try synchronizer(handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Close the file, putting the actual dimensions in the title.
    ///
    /// Compatibility path for callers that require a completely durable WAV
    /// before return. Live dictation uses the split methods above.
    @discardableResult
    public func close() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw Failure.notOpen }
        // The handle is freed anyway. Otherwise unsuccessful closing
        // would leave the file open forever: writer is unavailable after this, and
        // there is no one else to close it - this is how the limit is reached in a day of dictation
        // open process files.
        defer {
            self.handle = nil
            isSealed = false
        }

        do {
            if !isSealed { try sealLocked(handle) }
            try synchronizer(handle)
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
        isSealed = false
        try? FileManager.default.removeItem(at: url)
    }

    /// Release the descriptor but leave the raw take where crash recovery can
    /// repair its header on the next launch.
    ///
    /// This is intentionally different from `discard()`: a disk queue failure
    /// means the file may be incomplete, but deleting the bytes that did make
    /// it to storage would turn a partial recovery into no recovery at all.
    public func abandonForRecovery() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        isSealed = false
    }

    private func sealLocked(_ handle: FileHandle) throws {
        // The dimensions are known only now - rewrite the placeholder header.
        try handle.seek(toOffset: 0)
        try dataWriter(handle, header(dataBytes: bytesWritten))
        isSealed = true
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
