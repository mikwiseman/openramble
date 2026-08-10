import DictationCore
import Foundation

/// Storing a custom dictionary of replacements.
///
/// The dictionary is the only thing that a person types in this application with his hands, and
/// the only value accumulated in it. Therefore, there is only one rule here:
/// **I couldn’t read it - I’m not writing.**
///
/// Substituting an empty array instead of an unread one (as was done before) means
/// at the first edit, overwrite the key with it. The dictionary disappears entirely, silently and
/// irreversible, but it looks like “the settings were reset by themselves.”
public struct ReplacementsStore {
    /// Storage format number.
    ///
    /// Needed for rollback. Open source is rolled back to a version regularly, and
    /// the old application must see “this is recorded by something newer” and not
    /// touch - otherwise, rolling back for a day destroys the dictionary accumulated over the month.
    static let currentVersion = 1

    /// Why the dictionary is locked for writing.
    public enum Problem: Sendable, Equatable {
        /// There is a key, but I couldn’t figure it out. The original data is set aside.
        case unreadable(quarantineKey: String)
        /// Recorded by a newer version of the application.
        case writtenByNewerVersion(Int)

        public var message: String {
            switch self {
            case .unreadable:
                return """
                    The replacement dictionary couldn't be read, so it can't be edited. \
                    The previous data is preserved — nothing is lost.
                    """
            case let .writtenByNewerVersion(version):
                return """
                    The replacement dictionary was written by a newer version of the app \
                    (format \(version)). It can't be edited so that version's data isn't lost.
                    """
            }
        }
    }

    struct Load: Equatable {
        var replacements: [DictionaryReplacement]
        /// Not nil - cannot be written.
        var problem: Problem?
    }

    /// Stored. The array is wrapped in an object just for the sake of the version number.
    private struct Envelope: Codable {
        let version: Int
        let items: [DictionaryReplacement]
    }

    /// Version number only, no content.
    ///
    /// Read separately and first. You cannot parse the version together with the elements:
    /// rollback catches exactly the case when elements are written in an unfamiliar form,
    /// and the analysis stumbles over them. Then “this is someone else’s version, don’t touch it”
    /// would turn into “did not read” - and the data of the new version would go under the knife.
    private struct VersionProbe: Codable {
        let version: Int
    }

    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date

    init(defaults: UserDefaults, key: String, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.key = key
        self.now = now
    }

    func load() -> Load {
        guard let data = defaults.data(forKey: key) else {
            // There is no key - normal first launch, the dictionary is empty. It's not an accident.
            return Load(replacements: [], problem: nil)
        }

        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) {
            guard probe.version >= 1 else {
                return Load(replacements: [], problem: .unreadable(quarantineKey: quarantine(data)))
            }
            guard probe.version <= Self.currentVersion else {
                // We don't put anything aside and don't touch anything: the data is intact, just
                // not ours. A new version will return and read them itself.
                return Load(replacements: [], problem: .writtenByNewerVersion(probe.version))
            }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                // Our version, but the contents are not parsed. Read half and
                // writing it back means losing the second one.
                return Load(replacements: [], problem: .unreadable(quarantineKey: quarantine(data)))
            }
            return Load(replacements: envelope.items, problem: nil)
        }

        // Old format: bare array without version number. We read it as it is, and in
        // the new one will move at the first entry.
        if let legacy = try? JSONDecoder().decode([DictionaryReplacement].self, from: data) {
            return Load(replacements: legacy, problem: nil)
        }

        return Load(replacements: [], problem: .unreadable(quarantineKey: quarantine(data)))
    }

    func save(_ replacements: [DictionaryReplacement]) throws {
        let data = try JSONEncoder().encode(
            Envelope(version: Self.currentVersion, items: replacements)
        )
        defaults.set(data, forKey: key)
    }

    /// Put unread things aside.
    ///
    /// Write to a NEW key, do not touch the original one: quarantine must be an addition,
    /// and not by moving, otherwise the rescue operation itself will lose the data.
    private func quarantine(_ data: Data) -> String {
        let formatter = ISO8601DateFormatter()
        let quarantineKey = "\(key).unreadable.\(formatter.string(from: now()))"
        defaults.set(data, forKey: quarantineKey)
        return quarantineKey
    }
}
