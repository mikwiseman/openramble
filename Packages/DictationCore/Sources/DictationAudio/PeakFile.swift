import Foundation

/// The waveform, precomputed while recording.
///
/// One byte per channel per 100 ms — the loudest sample in that bucket, never
/// the mean, because a mean hides a shout inside a quiet minute and this
/// file's job is to not hide things. Two hours is 144 kB. It is written as the
/// recording goes, so a crash leaves a waveform and a scrub never has to read
/// 460 MB of audio.
///
/// Layout: `"ORPK"`, version, channel count, frames per bucket, bucket count,
/// then the buckets interleaved by channel. The count in the header is patched
/// at close; a file that never closed reads its count from its size instead.
public final class PeakFile: @unchecked Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case cannotCreate(String)
        case writeFailed(String)
        case notOpen
        case malformed(String)
    }

    public struct Contents: Sendable, Equatable {
        public let framesPerBucket: Int
        /// One array per channel, values in 0…1.
        public let channels: [[Float]]
    }

    public static let magic = Data("ORPK".utf8)
    public static let version: UInt16 = 1
    public static let headerBytes = 16
    /// 100 ms at 16 kHz.
    public static let defaultFramesPerBucket = 1_600

    public let url: URL
    public let channelCount: Int
    public let framesPerBucket: Int

    private let lock = NSLock()
    private var handle: FileHandle?
    private var bucketCount = 0

    public init(
        url: URL,
        channelCount: Int = 2,
        framesPerBucket: Int = PeakFile.defaultFramesPerBucket
    ) {
        self.url = url
        self.channelCount = channelCount
        self.framesPerBucket = framesPerBucket
    }

    public func open() throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { throw Failure.notOpen }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw Failure.cannotCreate(url.path)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: header(bucketCount: 0))
            self.handle = handle
            bucketCount = 0
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// One bucket: a peak per channel in 0…1.
    public func append(_ peaks: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw Failure.notOpen }
        guard peaks.count == channelCount else {
            throw Failure.writeFailed("expected \(channelCount) peaks, got \(peaks.count)")
        }
        let bytes = peaks.map { UInt8((max(0, min(1, $0)) * 255).rounded()) }
        do {
            try handle.write(contentsOf: Data(bytes))
            bucketCount += 1
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw Failure.notOpen }
        defer { self.handle = nil }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(bucketCount: bucketCount))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Release the descriptor without patching the count — what a crash does.
    public func abandon() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    public static func read(url: URL) throws -> Contents {
        // `contents(atPath:)` rather than `Data(contentsOf:)`: the latter also
        // fetches remote URLs and is banned by the network gate for it.
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw Failure.malformed("unreadable")
        }
        guard data.count >= headerBytes, data.prefix(4) == magic else {
            throw Failure.malformed("not a peak file")
        }
        let channelCount = Int(data.readUInt16(at: 6))
        let framesPerBucket = Int(data.readUInt32(at: 8))
        guard channelCount > 0, framesPerBucket > 0 else {
            throw Failure.malformed("empty channel or bucket size")
        }
        // The header count is what was patched at close. A file that never
        // closed has a zero there and every bucket that reached disk after
        // it, so the size is the truth either way.
        let available = (data.count - headerBytes) / channelCount
        var channels = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount { channels[channel].reserveCapacity(available) }
        for bucket in 0..<available {
            let base = headerBytes + bucket * channelCount
            for channel in 0..<channelCount {
                channels[channel].append(Float(data[base + channel]) / 255)
            }
        }
        return Contents(framesPerBucket: framesPerBucket, channels: channels)
    }

    private func header(bucketCount: Int) -> Data {
        var data = Data()
        data.append(Self.magic)
        data.appendUInt16(Self.version)
        data.appendUInt16(UInt16(channelCount))
        data.appendUInt32(UInt32(framesPerBucket))
        data.appendUInt32(UInt32(bucketCount))
        return data
    }
}

extension Data {
    fileprivate mutating func appendUInt16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    fileprivate func readUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(self[startIndex + offset + i]) << (8 * UInt32(i)) }
        return value
    }
}
