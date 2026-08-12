import Foundation

// `RecoveryStore` used to live here, writing unrecognized text to disk.
// Now such text is kept only in process memory (Copy/Retry in the menu),
// and only WAVs end up on the disk after a technical error - see below.
// The `Recovered/` directory of old assemblies is removed by the application at startup.

/// WAV remaining after a technical error and available for re-ASR.
public protocol RecordingRecoveryStoring: Sendable {
    func preserve(_ source: URL) async throws -> URL?
}

public struct AbandonedRecordingImportResult: Sendable, Equatable {
    public let recordings: [URL]
    /// How many recordings this very import rescued.
    ///
    /// Tells "something happened right now" apart from "left over from last
    /// week": an old leftover is not an event of this launch, and announcing
    /// it again would be a made-up error.
    public let newlyImportedCount: Int
    public let discardedCorruptCount: Int

    public init(recordings: [URL], newlyImportedCount: Int, discardedCorruptCount: Int) {
        self.recordings = recordings
        self.newlyImportedCount = newlyImportedCount
        self.discardedCorruptCount = discardedCorruptCount
    }
}

/// Production recovery for erroneous and interrupted recordings.
public actor RecordingRecoveryStore: RecordingRecoveryStoring {
    private let directory: URL
    private let maximumCount: Int
    private let maximumAge: TimeInterval
    private let maximumBytes: Int64
    private let fileManager: FileManager

    public init(
        directory: URL,
        maximumCount: Int = 10,
        maximumAge: TimeInterval = 7 * 24 * 3600,
        maximumBytes: Int64 = 1_073_741_824,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.maximumCount = maximumCount
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
    }

    public func preserve(_ source: URL) throws -> URL? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination: URL
        if source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            destination = source
        } else {
            destination = directory.appending(
                path: "recording-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(8)).wav"
            )
            try fileManager.moveItem(at: source, to: destination)
        }
        try prune()
        return fileManager.fileExists(atPath: destination.path) ? destination : nil
    }

    /// Transfer WAV remaining to Takes after kill/crash/power loss.
    public func importAbandoned(from takesDirectory: URL) throws -> AbandonedRecordingImportResult {
        guard fileManager.fileExists(atPath: takesDirectory.path) else {
            return AbandonedRecordingImportResult(
                recordings: try recordings(),
                newlyImportedCount: 0,
                discardedCorruptCount: 0
            )
        }
        let entries = try fileManager.contentsOfDirectory(
            at: takesDirectory,
            includingPropertiesForKeys: nil
        )
        var newlyImportedCount = 0
        var discardedCorruptCount = 0
        for entry in entries where entry.pathExtension.lowercased() == "wav" {
            do {
                let payloadBytes = try repairAbandonedWAV(at: entry)
                // A fragment shorter than the recognition minimum is an
                // accidental key press that outlived a kill, not lost speech.
                // The main dictation path deletes such takes silently; the
                // import must behave the same — otherwise every launch shows
                // "a recording after a failure" whose retry can only ever
                // produce an empty result.
                guard DictationDurationPolicy.isWorthTranscribing(
                    duration: TimeInterval(payloadBytes) / TimeInterval(Self.bytesPerSecond)
                ) else {
                    try fileManager.removeItem(at: entry)
                    continue
                }
                if try preserve(entry) != nil { newlyImportedCount += 1 }
            } catch let error as CocoaError where error.code == .fileReadCorruptFile {
                // An exactly unusable fragment should not block the rest
                // records after crash. This is just the native WAVWriter file from
                //Takes; other people's files do not go here. The deletion will reach the UI
                // counter, so it is not hidden from humans.
                try fileManager.removeItem(at: entry)
                discardedCorruptCount += 1
            }
        }
        return AbandonedRecordingImportResult(
            recordings: try recordings(),
            newlyImportedCount: newlyImportedCount,
            discardedCorruptCount: discardedCorruptCount
        )
    }

    /// Byte rate of our own WAVWriter stream: 16 kHz × 16-bit × mono.
    /// The format is pinned by the header check in `repairAbandonedWAV`.
    private static let bytesPerSecond: Int64 = 32_000

    /// WAVWriter first puts a 44-byte header with zero dimensions and
    /// fixes them in `close()`. After kill/crash PCM is already on the disk, but without
    /// of this fix, the system decoder considers the entry empty. We only accept
    /// the exact format of the writer's own: someone else's or cropped file should not
    /// masquerade as a suitable Retry.
    ///
    /// Returns the PCM payload size: it decides whether the recording holds
    /// anything worth transcribing.
    @discardableResult
    private func repairAbandonedWAV(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        let totalBytes = fileSize.int64Value
        guard totalBytes >= 44 else { throw CocoaError(.fileReadCorruptFile) }
        let payloadBytes = totalBytes - 44
        guard payloadBytes.isMultiple(of: 2), payloadBytes <= Int64(UInt32.max) - 36 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let handle = try FileHandle(forUpdating: url)
        do {
            try handle.seek(toOffset: 0)
            guard let header = try handle.read(upToCount: 44), header.count == 44,
                  String(decoding: header[0..<4], as: UTF8.self) == "RIFF",
                  String(decoding: header[8..<16], as: UTF8.self) == "WAVEfmt ",
                  readUInt32(header, at: 16) == 16,
                  readUInt16(header, at: 20) == 1,
                  readUInt16(header, at: 22) == 1,
                  readUInt32(header, at: 24) == 16_000,
                  readUInt32(header, at: 28) == 32_000,
                  readUInt16(header, at: 32) == 2,
                  readUInt16(header, at: 34) == 16,
                  String(decoding: header[36..<40], as: UTF8.self) == "data"
            else {
                throw CocoaError(.fileReadCorruptFile)
            }

            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: littleEndian(UInt32(36 + payloadBytes)))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: littleEndian(UInt32(payloadBytes)))
            try handle.synchronize()
            try handle.close()
        } catch {
            // The close error should be visible, but re-closing after more
            // early error - only releasing the handle.
            try? handle.close()
            throw error
        }
        return payloadBytes
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    public func recordings() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try entries().sorted { $0.date > $1.date }.map(\.url)
    }

    public func delete(_ url: URL) throws {
        let prefix = directory.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.removeItem(at: url)
    }

    private struct Entry {
        let url: URL
        let date: Date
        let bytes: Int64
    }

    private func entries() throws -> [Entry] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        return try urls.filter { $0.pathExtension.lowercased() == "wav" }.map { url in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values.contentModificationDate, let size = values.fileSize else {
                throw CocoaError(.fileReadUnknown)
            }
            return Entry(url: url, date: date, bytes: Int64(size))
        }
    }

    private func prune(now: Date = Date()) throws {
        var survivors: [Entry] = []
        for entry in try entries().sorted(by: { $0.date < $1.date }) {
            if now.timeIntervalSince(entry.date) > maximumAge {
                try fileManager.removeItem(at: entry.url)
            } else {
                survivors.append(entry)
            }
        }

        var totalBytes = survivors.reduce(Int64(0)) { $0 + $1.bytes }
        while survivors.count > maximumCount || totalBytes > maximumBytes {
            let oldest = survivors.removeFirst()
            try fileManager.removeItem(at: oldest.url)
            totalBytes -= oldest.bytes
        }
    }
}

/// Old unit tests and pure consumers can explicitly choose to remove WAV.
public struct DiscardingRecordingRecovery: RecordingRecoveryStoring {
    public init() {}

    public func preserve(_ source: URL) throws -> URL? {
        try FileManager.default.removeItem(at: source)
        return nil
    }
}
