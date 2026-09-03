import DictationAudio
import DictationCore
import Foundation

/// The recordings on disk: one directory per recording, named by its UUID.
///
/// ```
/// Recordings/
///   <uuid>/            published
///     audio.wav        stereo 16 kHz; L = microphone, R = system audio
///     meta.json
///     transcript.json
///     peaks.bin
///   .incomplete/<uuid>/  in progress, or abandoned by a crash
/// ```
///
/// A recording is written under `.incomplete/` and moved into place when it
/// ends — a rename within a volume, O(1) at any size — so the list never
/// contains a half-written directory. Whatever a crash leaves behind is
/// repaired and published at the next launch.
///
/// **Not `DictationHistoryStore`, on purpose.** That store is a bounded list
/// of short takes with a Rust mirror in `core/ramble-history` that must
/// follow every schema change. A recording is unbounded, has a transcript
/// that grows while it records, and exists only on macOS. Keeping it apart
/// keeps the Rust obligation at zero and the history's retention rule
/// honest. A voice note is a meeting with one participant.
public struct MeetingStore: Sendable {
    public static let incompleteDirectoryName = ".incomplete"
    public static let metadataFileName = "meta.json"
    public static let transcriptFileName = "transcript.json"

    public typealias Trasher = @Sendable (URL) throws -> Void

    private let root: URL
    /// Deletion is a move to the Trash — the user's own, visible in Finder,
    /// emptied on their schedule, and how every Mac app deletes a document.
    /// One API call protects a two-hour recording from a mis-click, with no
    /// second store to build and no sweep to run. Injectable so a test can
    /// remove rather than fill the developer's Trash.
    private let trasher: Trasher

    public init(
        root: URL,
        trasher: @escaping Trasher = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.root = root
        self.trasher = trasher
    }

    private var fileManager: FileManager { .default }

    // MARK: - Paths

    public var incompleteRoot: URL {
        root.appending(path: Self.incompleteDirectoryName, directoryHint: .isDirectory)
    }

    public func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public func incompleteDirectory(for id: UUID) -> URL {
        incompleteRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public func audioURL(for id: UUID) -> URL? {
        existing(directory(for: id).appending(path: MeetingWriter.audioFileName, directoryHint: .notDirectory))
    }

    public func peaksURL(for id: UUID) -> URL? {
        existing(directory(for: id).appending(path: MeetingWriter.peaksFileName, directoryHint: .notDirectory))
    }

    private func existing(_ url: URL) -> URL? {
        fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Reading

    /// Every published recording, newest first. Only directories whose name
    /// parses as a UUID count, which also skips `.incomplete` and `.DS_Store`
    /// without a filter for either.
    public func list() -> [MeetingRecordingMetadata] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { metadata(for: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Whether the recording has ended and moved into the list.
    public func isPublished(_ id: UUID) -> Bool {
        fileManager.fileExists(atPath: directory(for: id).path)
    }

    public func metadata(for id: UUID) -> MeetingRecordingMetadata? {
        read(MeetingRecordingMetadata.self, at: directory(for: id).appending(path: Self.metadataFileName))
    }

    public func transcript(for id: UUID) -> MeetingTranscript? {
        read(MeetingTranscript.self, at: directory(for: id).appending(path: Self.transcriptFileName))
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        // `contents(atPath:)` rather than `Data(contentsOf:)`: the latter also
        // fetches remote URLs and the network gate rightly refuses it.
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        // A damaged file is not worth failing the launch over, and not worth
        // deleting either — the audio beside it is intact and still plays.
        return try? MeetingRecordingCoding.decoder().decode(type, from: data)
    }

    /// Everything the recordings occupy, for the person to see and manage.
    public func totalBytes() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// What one recording occupies.
    public func bytes(for id: UUID) -> Int64 {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory(for: id),
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - Writing

    public func write(_ metadata: MeetingRecordingMetadata, incomplete: Bool = false) throws {
        let directory = incomplete ? incompleteDirectory(for: metadata.id) : self.directory(for: metadata.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try MeetingRecordingCoding.encoder().encode(metadata)
            .write(to: directory.appending(path: Self.metadataFileName), options: .atomic)
    }

    public func write(_ transcript: MeetingTranscript, for id: UUID, incomplete: Bool = false) throws {
        let directory = incomplete ? incompleteDirectory(for: id) : self.directory(for: id)
        try MeetingRecordingCoding.encoder().encode(transcript)
            .write(to: directory.appending(path: Self.transcriptFileName), options: .atomic)
    }

    /// Move a finished recording into the list.
    public func publish(_ id: UUID) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.moveItem(at: incompleteDirectory(for: id), to: directory(for: id))
    }

    @discardableResult
    public func rename(_ id: UUID, title: String?) throws -> MeetingRecordingMetadata? {
        guard var metadata = metadata(for: id) else { return nil }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try write(metadata)
        return metadata
    }

    public func trash(_ id: UUID) throws {
        try trasher(directory(for: id))
    }

    // MARK: - Recovery

    /// Repair and publish whatever a crash left under `.incomplete/`.
    ///
    /// The WAV header of an unfinished recording still says zero bytes; the
    /// audio after it is intact. A directory whose file is still held by a
    /// live process — a dev build beside a release build — is left alone.
    public func recoverIncomplete(now: Date = Date()) -> [MeetingRecordingMetadata] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: incompleteRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var recovered: [MeetingRecordingMetadata] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            let audio = entry.appending(path: MeetingWriter.audioFileName, directoryHint: .notDirectory)
            guard fileManager.fileExists(atPath: audio.path) else {
                // Nothing recorded at all: a directory with no audio is not a
                // recording anyone can want back.
                try? fileManager.removeItem(at: entry)
                continue
            }
            guard !RecordingFileLease.isActivelyHeld(at: audio) else { continue }
            guard let frames = try? MeetingWriter.repairHeader(at: audio) else { continue }
            var metadata = read(MeetingRecordingMetadata.self, at: entry.appending(path: Self.metadataFileName))
                ?? MeetingRecordingMetadata(
                    id: id,
                    startedAt: (try? audio.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now,
                    systemAudio: SystemAudioSummary(wasRequested: false)
                )
            metadata.duration = Double(frames) / Double(MeetingWriter.sampleRate)
            metadata.endReason = .crashRecovered
            if metadata.transcriptionState == .live { metadata.transcriptionState = .partial }
            guard (try? write(metadata, incomplete: true)) != nil,
                  (try? publish(id)) != nil else { continue }
            recovered.append(metadata)
        }
        return recovered
    }
}
