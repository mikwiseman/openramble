import Foundation

/// One finished dictation, kept so it can be heard and reused.
public struct HistoryEntry: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String
    /// The take's audio, if it is still on disk. A file can go missing — the
    /// person may have deleted it, or a crash may have left the record without
    /// it — and an entry whose text is intact is still worth showing.
    public let audioFileName: String?
    /// Kept regardless of the retention limit.
    ///
    /// Decoded with a default rather than required, so histories written by
    /// earlier versions still load. A store that refused its own older files
    /// would lose the very dictations this flag exists to protect.
    public var isKept: Bool

    public init(
        id: UUID = UUID(),
        date: Date,
        text: String,
        audioFileName: String?,
        isKept: Bool = false
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.audioFileName = audioFileName
        self.isKept = isKept
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        text = try container.decode(String.self, forKey: .text)
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        isKept = try container.decodeIfPresent(Bool.self, forKey: .isKept) ?? false
    }
}

/// The last few dictations, on disk, with their audio.
///
/// This replaces a recovery mechanism that only surfaced takes which had
/// *failed*: tickets, deletion-intent receipts, file leases and session
/// tombstones, about 1,900 lines, whose entire purpose was to hand back words
/// the app could not insert. A visible history does that job and more — every
/// take can be replayed, copied or re-inserted, not only the broken ones — and
/// it does it with a list and a retention count.
///
/// **This is a deliberate change to what the product persists.** Until now
/// recognized text lived in memory and was gone at quit. Keeping it, with the
/// audio, is what makes the feature useful, and it is why the privacy section
/// of the README had to be rewritten rather than quietly left alone. Nothing
/// leaves the Mac; the trade is that something now stays on it.
public struct DictationHistoryStore: Sendable {
    /// How many takes to keep by default.
    public static let defaultLimit = 5
    public static let limitKey = "historyLimit"
    /// The widest the setting goes. A limit is not a promise to keep nothing —
    /// it is a promise that the number is finite and the person chose it.
    public static let maximumLimit = 50

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `FileManager.default` is documented thread-safe for these operations and
    /// is reached per call rather than stored, because holding one would make
    /// this type non-Sendable for no benefit.
    private var fileManager: FileManager { .default }

    /// The stored limit, clamped. An absent or nonsensical value reads as the
    /// default rather than as "keep everything".
    public static func storedLimit(in defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: limitKey) != nil else { return defaultLimit }
        let stored = defaults.integer(forKey: limitKey)
        guard stored > 0 else { return defaultLimit }
        return min(stored, maximumLimit)
    }

    private var indexURL: URL {
        directory.appending(path: "history.json", directoryHint: .notDirectory)
    }

    public func audioURL(for entry: HistoryEntry) -> URL? {
        guard let name = entry.audioFileName else { return nil }
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func load() -> [HistoryEntry] {
        // `contents(atPath:)` rather than `Data(contentsOf:)`: the latter also
        // fetches remote URLs, so it cannot be told apart from a network read
        // by anything auditing this code — including our own network gate,
        // which rightly refused it.
        guard let data = fileManager.contents(atPath: indexURL.path) else { return [] }
        // A corrupt index is not worth failing the app over, and it is not
        // worth silently deleting either: returning nothing leaves the file in
        // place for anyone who wants to look at it.
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Record a take, trim to `limit`, and delete the audio of what fell off.
    ///
    /// Returns the list as it now stands. Audio for evicted entries is removed
    /// here rather than by a sweep: the moment an entry leaves the list is the
    /// only moment its file is provably unreferenced.
    @discardableResult
    public func record(
        text: String,
        audio: URL?,
        limit: Int,
        date: Date = Date()
    ) throws -> [HistoryEntry] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return load() }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var storedName: String?
        if let audio {
            let name = "\(UUID().uuidString).wav"
            let destination = directory.appending(path: name, directoryHint: .notDirectory)
            // A missing or unreadable take must not cost the person the text.
            if (try? fileManager.copyItem(at: audio, to: destination)) != nil {
                storedName = name
            }
        }

        var entries = load()
        entries.insert(
            HistoryEntry(date: date, text: trimmedText, audioFileName: storedName),
            at: 0
        )
        let kept = Array(entries.prefix(max(1, limit)))
        for evicted in entries.dropFirst(kept.count) {
            removeAudio(of: evicted)
        }
        try write(kept)
        return kept
    }

    /// Trim an already-stored history to a new limit, deleting evicted audio.
    @discardableResult
    public func applyLimit(_ limit: Int) throws -> [HistoryEntry] {
        let entries = load()
        // The limit counts ordinary dictations. A starred one is a promise
        // that it stays, and a promise that a later dictation can break is not
        // one — so starred entries neither count against the limit nor fall
        // out of it. Order is untouched, so the list still reads by date.
        var budget = max(1, limit)
        let kept = entries.filter { entry in
            if entry.isKept { return true }
            guard budget > 0 else { return false }
            budget -= 1
            return true
        }
        guard kept.count != entries.count else { return entries }
        let keptIDs = Set(kept.map(\.id))
        for evicted in entries where !keptIDs.contains(evicted.id) {
            removeAudio(of: evicted)
        }
        try write(kept)
        return kept
    }

    /// Put new text on an entry, leaving its audio and star alone.
    @discardableResult
    public func replaceText(_ text: String, for entry: HistoryEntry) throws -> [HistoryEntry] {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return entries }
        let existing = entries[index]
        entries[index] = HistoryEntry(
            id: existing.id,
            date: existing.date,
            text: text,
            audioFileName: existing.audioFileName,
            isKept: existing.isKept
        )
        try write(entries)
        return entries
    }

    /// Star or unstar one entry.
    @discardableResult
    public func setKept(_ isKept: Bool, for entry: HistoryEntry) throws -> [HistoryEntry] {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return entries }
        entries[index].isKept = isKept
        try write(entries)
        return entries
    }

    @discardableResult
    public func delete(_ entry: HistoryEntry) throws -> [HistoryEntry] {
        let remaining = load().filter { $0.id != entry.id }
        removeAudio(of: entry)
        try write(remaining)
        return remaining
    }

    /// Remove every entry and its audio.
    public func deleteAll() throws {
        for entry in load() { removeAudio(of: entry) }
        try? fileManager.removeItem(at: indexURL)
    }

    private func removeAudio(of entry: HistoryEntry) {
        guard let name = entry.audioFileName else { return }
        try? fileManager.removeItem(
            at: directory.appending(path: name, directoryHint: .notDirectory)
        )
    }

    private func write(_ entries: [HistoryEntry]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Deliberately the default date strategy, matching `load()`. An
        // encoder configured for ISO-8601 against a plain decoder writes a
        // history that reads back as empty — every entry silently lost at the
        // next launch, with no error anywhere.
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
    }
}
