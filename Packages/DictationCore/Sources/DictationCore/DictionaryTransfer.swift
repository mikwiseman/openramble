import Foundation

/// Moving the personal dictionary between Macs as a file.
///
/// The file is a versioned JSON envelope, deliberately independent of the
/// on-disk store: no internal ids leak out, absent flags mean their defaults,
/// and a hand-edited file with just `spoken`/`written` pairs imports cleanly.
public enum DictionaryTransfer {
    /// Format marker and version. The marker keeps a random JSON file from
    /// silently importing as an empty dictionary; the version lets a future
    /// format refuse politely instead of misreading.
    public static let currentVersion = 1

    public enum TransferError: Error, LocalizedError, Equatable {
        case notADictionaryFile
        case newerFormat(Int)
        case damaged(String)

        public var errorDescription: String? {
            switch self {
            case .notADictionaryFile:
                return "This file is not an OpenRamble dictionary."
            case let .newerFormat(version):
                return "This dictionary file needs a newer version of OpenRamble (format \(version))."
            case let .damaged(detail):
                return "The dictionary file couldn't be read: \(detail)"
            }
        }
    }

    private struct Envelope: Codable {
        var openRambleDictionary: Int
        var replacements: [Entry]
    }

    /// A portable entry: flags appear only when they differ from defaults,
    /// so exported files stay short and human-editable.
    private struct Entry: Codable {
        var spoken: String
        var written: String
        var inflects: Bool?
        var noAcousticBoost: Bool?
        var allowsPhoneticMatching: Bool?

        init(_ replacement: DictionaryReplacement) {
            spoken = replacement.spoken
            written = replacement.written
            inflects = replacement.inflects ? nil : false
            noAcousticBoost = replacement.noAcousticBoost ? true : nil
            allowsPhoneticMatching = replacement.allowsPhoneticMatching ? nil : false
        }

        var replacement: DictionaryReplacement? {
            let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty, !written.isEmpty else { return nil }
            return DictionaryReplacement(
                spoken: spoken,
                written: written,
                inflects: inflects ?? true,
                noAcousticBoost: noAcousticBoost ?? false,
                allowsPhoneticMatching: allowsPhoneticMatching ?? true
            )
        }
    }

    public static func export(_ replacements: [DictionaryReplacement]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            Envelope(
                openRambleDictionary: currentVersion,
                replacements: replacements.map(Entry.init)
            )
        )
    }

    /// Parses a file into fresh replacements. Entries that are empty after
    /// trimming are dropped silently — they carry no phrase to import.
    public static func read(_ data: Data) throws -> [DictionaryReplacement] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            // Valid JSON without our marker is someone else's file, not damage.
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                throw TransferError.notADictionaryFile
            }
            throw TransferError.damaged(error.localizedDescription)
        }
        guard envelope.openRambleDictionary <= currentVersion else {
            throw TransferError.newerFormat(envelope.openRambleDictionary)
        }
        return envelope.replacements.compactMap(\.replacement)
    }

    public struct MergeResult: Equatable {
        public let replacements: [DictionaryReplacement]
        public let added: Int
        public let updated: Int
    }

    /// Imports never destroy: existing entries keep their place and identity,
    /// an imported entry with the same spoken phrase (case-insensitively)
    /// updates it, everything else is appended in file order. Entries that
    /// change nothing are not counted — "0 new, 0 updated" means the file and
    /// the dictionary already agree.
    public static func merge(
        existing: [DictionaryReplacement],
        imported: [DictionaryReplacement]
    ) -> MergeResult {
        var result = existing
        var indexBySpoken: [String: Int] = [:]
        for (index, replacement) in existing.enumerated() {
            indexBySpoken[key(replacement.spoken)] = index
        }

        var added = 0
        var updated = 0
        for incoming in imported {
            if let index = indexBySpoken[key(incoming.spoken)] {
                let current = result[index]
                // The row keeps its identity: an update is an edit, not a
                // delete-and-recreate that would reshuffle the list.
                let replaced = DictionaryReplacement(
                    id: current.id,
                    spoken: incoming.spoken,
                    written: incoming.written,
                    inflects: incoming.inflects,
                    noAcousticBoost: incoming.noAcousticBoost,
                    allowsPhoneticMatching: incoming.allowsPhoneticMatching
                )
                guard replaced != current else { continue }
                result[index] = replaced
                updated += 1
            } else {
                result.append(incoming)
                indexBySpoken[key(incoming.spoken)] = result.count - 1
                added += 1
            }
        }
        return MergeResult(replacements: result, added: added, updated: updated)
    }

    private static func key(_ spoken: String) -> String {
        spoken.lowercased()
    }
}
