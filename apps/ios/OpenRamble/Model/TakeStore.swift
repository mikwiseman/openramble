import Foundation
import Observation

/// Every take, on this iPhone only.
///
/// One small JSON index plus one audio file per take, in Application Support.
/// The folder is excluded from iCloud Backup, and its files are readable after
/// the first unlock, so a take recorded on the Lock Screen can be written while
/// the iPhone stays locked. Takes stay until the person deletes them; README's
/// privacy section says so.
@MainActor
@Observable
final class TakeStore {
    private(set) var takes: [Take] = []
    /// The last failure to save, shown to the person rather than swallowed.
    private(set) var saveFailure: String?

    let root: URL
    private let indexURL: URL
    let audioFolder: URL

    init(root: URL) {
        self.root = root
        indexURL = root.appending(path: "takes.json")
        audioFolder = root.appending(path: "audio", directoryHint: .isDirectory)
        prepareFolders()
        load()
    }

    /// The store the app uses: Application Support/Takes.
    static func standard() -> TakeStore {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        return TakeStore(root: support.appending(path: "Takes", directoryHint: .isDirectory))
    }

    // MARK: - Reading

    func take(_ id: Take.ID) -> Take? {
        takes.first { $0.id == id }
    }

    func audioURL(for take: Take) -> URL? {
        guard let name = take.audioFileName else { return nil }
        let url = audioFolder.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The newest take that has words: what "Copy last take" copies.
    var latestWritten: Take? {
        takes.last { $0.hasWords }
    }

    /// Takes whose writing never finished: recorded, then the app was closed
    /// or the system ended it before the words arrived.
    var unfinished: [Take] {
        takes.filter { $0.state == .writing }
    }

    /// Where a new take's audio goes.
    func newAudioURL(for id: Take.ID, extension ext: String = "wav") -> URL {
        audioFolder.appending(path: "\(id.uuidString).\(ext)")
    }

    // MARK: - Writing

    func insert(_ take: Take) {
        takes.append(take)
        takes.sort { $0.recordedAt < $1.recordedAt }
        save()
    }

    func update(_ take: Take) {
        guard let index = takes.firstIndex(where: { $0.id == take.id }) else { return }
        takes[index] = take
        save()
    }

    func delete(_ id: Take.ID) {
        guard let index = takes.firstIndex(where: { $0.id == id }) else { return }
        let take = takes.remove(at: index)
        if let name = take.audioFileName {
            try? FileManager.default.removeItem(at: audioFolder.appending(path: name))
        }
        save()
    }

    // MARK: - Disk

    private func prepareFolders() {
        let manager = FileManager.default
        try? manager.createDirectory(at: audioFolder, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        // Excluded from iCloud Backup: nothing the person says leaves the iPhone.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = root
        try? folder.setResourceValues(values)
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: indexURL.path) else { return }
        do {
            takes = try JSONDecoder.takes.decode([Take].self, from: data)
                .sorted { $0.recordedAt < $1.recordedAt }
        } catch {
            // An index that cannot be read is moved aside, never overwritten:
            // the audio files are still there and the index can be recovered.
            let aside = root.appending(path: "takes-unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: aside)
            saveFailure = "The list of takes could not be read and was set aside."
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder.takes.encode(takes)
            try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            saveFailure = nil
        } catch {
            saveFailure = "Your takes could not be saved: \(error.localizedDescription)"
        }
    }
}

extension JSONEncoder {
    static var takes: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var takes: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
