I want to move my dictionary between Macs and keep a copy of it. Build the file format and the merge in DictationCore now; the Settings buttons come later, so leave the app alone.

The file is JSON a person can also write by hand. A file that holds only spoken and written pairs must import, with every other setting at its default. An exported file carries no internal ids, and settings that are at their default stay out of it, so a plain pair is written as just its two fields. Phrases whose spoken or written side is empty or only spaces are dropped on import, and both sides are trimmed.

Importing must never lose or reshuffle what I already have. A phrase I already have, compared without regard to case, is updated where it stands and keeps its identity; new phrases are added after mine in the order of the file. Report how many were added and how many updated, and count only real changes: importing what I already have changes nothing and counts nothing.

A JSON file from some other app is refused as not being a dictionary, a file from a newer OpenRamble is refused politely with its version, and bytes that are not readable are reported as damaged.

The tests will call this interface in DictationCore. Use these names and shapes; everything else is yours.

```swift
public enum DictionaryTransfer {
    /// The format version this build writes and reads: 1.
    public static let currentVersion: Int
    public enum TransferError: Error, Equatable {
        case notADictionaryFile
        case newerFormat(Int)
        case damaged(String)
    }
    /// {"openRambleDictionary": 1, "replacements": [{"spoken": ..., "written": ...}, ...]}
    public static func export(_ replacements: [DictionaryReplacement]) throws -> Data
    public static func read(_ data: Data) throws -> [DictionaryReplacement]
    public struct MergeResult: Equatable {
        public let replacements: [DictionaryReplacement]
        public let added: Int
        public let updated: Int
    }
    public static func merge(existing: [DictionaryReplacement], imported: [DictionaryReplacement]) -> MergeResult
}
```
