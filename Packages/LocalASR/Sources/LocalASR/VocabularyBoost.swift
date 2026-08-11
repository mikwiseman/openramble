import DictationCore
import Foundation

/// Terms that recognition must recognize at the sound level.
///
/// This is not a replacement dictionary: replacements fix the text after recognition, and these
/// the terms go to the acoustic prompt (CTC keyword spotting) and change
/// the result itself. The type lives separately from FluidAudio, so that the preparation rules
/// lists were checked without a model.
public struct VocabularyBoost: Sendable, Equatable {
    public struct Term: Sendable, Equatable {
        public let text: String
        /// Alternative spellings of the same term - first of all
        /// Cyrillic: the model text inside a Russian phrase is Cyrillic, and
        /// without such a bridge, there is no candidate for replacement at all.
        public let aliases: [String]

        /// Aliases are normalized as terms: empty is thrown away, edges
        /// are cut off, duplicates and matches to the term itself are collapsed.
        public init(text: String, aliases rawAliases: [String] = []) {
            self.text = text
            var seen: Set<String> = [text.lowercased()]
            var prepared: [String] = []
            for raw in rawAliases {
                let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !alias.isEmpty else { continue }
                guard seen.insert(alias.lowercased()).inserted else { continue }
                prepared.append(alias)
            }
            aliases = prepared
        }
    }

    public let terms: [Term]

    /// How similar a word in the text should be to a term or alias,
    /// to qualify for replacement (0…1). Below - wider coverage and more false ones
    /// triggers in ordinary speech; higher - be careful. Value selected
    /// by measuring on the body: see docs/benchmarks.md.
    public let minSimilarity: Float

    /// To what extent should the acoustic evidence of a term outweigh the original
    /// word. More - replacement is more aggressive; ordinary Russian speech, similar to
    /// term by sound (“in the center” and Sentry), suffers first.
    public let biasWeight: Float

    public var isEmpty: Bool { terms.isEmpty }

    /// Empty lines are discarded, whitespace is trimmed, duplicates are removed
    /// collapse case insensitive - the first spelling wins: his
    /// the person entered it himself.
    public init(terms rawTerms: [Term], minSimilarity: Float = 0.65, biasWeight: Float = 3.0) {
        var seen = Set<String>()
        var prepared: [Term] = []
        for term in rawTerms {
            let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = text.lowercased()
            guard seen.insert(key).inserted else { continue }
            prepared.append(Term(text: text, aliases: term.aliases))
        }
        terms = prepared
        self.minSimilarity = min(1, max(0, minSimilarity))
        self.biasWeight = biasWeight
    }
}

extension VocabularyBoost {
    /// Terms that a person keeps away from acoustics.
    ///
    /// Previously, there was a hardcoded list of three words here. Now decides
    /// the entry itself is `DictionaryReplacement.noAcousticBoost`, because
    /// each has its own terms: “kassa” catches “Kassa”, “sleigh” - “Sunny”, and ours
    /// a list of three words knew nothing about them. The reason why such
    /// terms are excluded altogether - in the documentation for the flag itself.
    static func unboostable(_ replacements: [DictionaryReplacement]) -> Set<String> {
        Set(
            replacements
                .filter(\.noAcousticBoost)
                .map { $0.written.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
    }

    /// Set according to the user's dictionary: starting terms plus his own
    /// replacements - including those learned from edits.
    public static func withUserReplacements(
        _ replacements: [DictionaryReplacement]
    ) -> VocabularyBoost {
        let defaults = developerDefault()
        let known = Set(defaults.terms.map { $0.text.lowercased() })
        // Marked by a person plus marked in the workpiece: custom
        // the record “deploy → deploy” does not have the right to return deploy to acoustics
        // only because there is no checkmark in it.
        // A personal text-only mark blocks that canonical term completely. For
        // built-ins, block only canonical terms with no safe acoustic spelling;
        // one exact-only repair must not suppress the other measured aliases.
        let starterWritten = Set(StarterDictionary.developer.map { $0.written.lowercased() })
        let unsafeStarterOnly = starterWritten.subtracting(known)
        let blocked = unboostable(replacements).union(unsafeStarterOnly)

        // Preserve the person's entry order while grouping aliases by canonical
        // spelling. A personal pronunciation of an existing built-in term must
        // extend that term instead of being discarded as a duplicate.
        var grouped: [(key: String, text: String, aliases: [String])] = []
        var groupedIndex: [String: Int] = [:]
        for replacement in replacements {
            let text = replacement.written.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = text.lowercased()
            guard !blocked.contains(key) else { continue }
            guard text.contains(where: { $0.isLetter && $0.isASCII }) else { continue }

            if let index = groupedIndex[key] {
                grouped[index].aliases.append(replacement.spoken)
            } else {
                groupedIndex[key] = grouped.count
                grouped.append((key, text, [replacement.spoken]))
            }
        }

        let mergedDefaults = defaults.terms.map { term in
            guard let index = groupedIndex[term.text.lowercased()] else { return term }
            return Term(text: term.text, aliases: term.aliases + grouped[index].aliases)
        }
        let userTerms = grouped
            .filter { !known.contains($0.key) }
            .map { Term(text: $0.text, aliases: $0.aliases) }
        return VocabularyBoost(terms: mergedDefaults + userTerms)
    }

    /// Ready-made set for the developer's dictionary: Latin term plus it
    /// Cyrillic spellings as pseudonyms - a bridge from sound to Latin.
    public static func developerDefault() -> VocabularyBoost {
        let starter = StarterDictionary.developer
        let grouped = Dictionary(grouping: starter, by: \.written)
        return VocabularyBoost(
            terms: grouped
                .compactMap { written, group in
                    // `noAcousticBoost` belongs to a spelling. A measured exact
                    // decoder repair may be unsafe as an acoustic alias while the
                    // canonical term and its normal aliases remain useful.
                    let aliases = group.filter { !$0.noAcousticBoost }
                    guard !aliases.isEmpty else { return nil }
                    return Term(text: written, aliases: aliases.map(\.spoken))
                }
                .sorted { $0.text < $1.text }
        )
    }
}

/// The problem is with the list of terms, not with the model.
///
/// A separate type exists for the sake of one difference that the user sees
/// eyes: `ASREngineError.modelsUnavailable` means “the scales are bad, you need to
/// download”, and the application honestly offers a recovery of 483 MB.
/// The term that cannot be translated into tokens is human data; pumping his model
/// will not fix it, but the proposal to do it is misleading and worth
/// traffic user. Catch this type separately and show the dictionary editing,
/// rather than restoring the model.
public enum VocabularyBoostError: Error, Sendable, Equatable {
    /// The term with this number (from one) cannot be expanded into
    /// tokens. The text of the term itself does not fall into error: the contents of the dictionary are
    /// the same person data as the dictation text.
    case termNotTokenizable(index: Int)
}

/// An engine that can show recognition live while a person is speaking.
///
/// Preview text is for eyes only: the source of truth remains
/// batch recognition of a finished record using the same engine.
public protocol LivePreviewCapable: Sendable {
    /// `confirmed` is the established text, `volatile` is the tail that can still
    /// change. Updates arrive no more than four times per second: flickering
    /// is more distracting than the delay.
    func startPreview(
        onUpdate: @escaping @Sendable (_ confirmed: String, _ volatile: String) -> Void
    ) async throws
    func feedPreview(samples: [Float]) async
    func stopPreview() async
}

extension FluidAudioAdapter: LivePreviewCapable {}

/// An engine that can accept acoustic hints of terms.
///
/// The protocol lives in LocalASR, not in DictationCore: the dictation core doesn't care
/// where the text came from, and the ability to “recognize terms by sound” is a property
/// specific engine.
public protocol VocabularyBoostCapable: Sendable {
    func loadVocabularyModels(from directory: URL, boost: VocabularyBoost) async throws
}

extension FluidAudioAdapter: VocabularyBoostCapable {}
