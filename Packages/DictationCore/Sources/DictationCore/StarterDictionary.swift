import Foundation

/// Ready-made replacements for those who dictate in Russian with English terms.
///
/// The model recognizes Russian speech and writes down Anglicisms as it hears them:
/// “pull request” becomes “pull request”, “Sentry” becomes “centry”. It's not a glitch
/// models, but natural behavior: inside the Russian phrase she should write
/// Cyrillic.
///
/// The dictionary returns the terms to their normal form. Safe terms are built into
/// every recognition pipeline; personal replacements remain separate and take priority.
public enum StarterDictionary {
    /// Developer terms.
    public static var developer: [DictionaryReplacement] {
        inflecting.map {
            DictionaryReplacement(
                spoken: $0.0,
                written: $0.1,
                noAcousticBoost: unboostable.contains($0.1),
                allowsPhoneticMatching: !nonPhonetic.contains($0.1)
            )
        }
            + literal.map {
                DictionaryReplacement(
                    spoken: $0.0,
                    written: $0.1,
                    inflects: false,
                    noAcousticBoost: unboostable.contains($0.1),
                    allowsPhoneticMatching: !nonPhonetic.contains($0.1)
                )
            }
            + postprocessingOnly.map {
                // These are exact, measured decoder spellings. They repair text
                // safely after recognition but are intentionally kept out of the
                // acoustic hint: several are fragments of ordinary Russian words.
                DictionaryReplacement(
                    spoken: $0.0,
                    written: $0.1,
                    inflects: false,
                    noAcousticBoost: true,
                    allowsPhoneticMatching: false
                )
            }
    }

    /// Terms whose Cyrillic sound is an ordinary Russian word.
    ///
    /// The flag lives **in the workpiece data**, and not in the filter on the tooltip side.
    /// The difference is not cosmetic: remove the list from `VocabularyBoost` and not
    /// putting a flag here means returning `deploy`, `Sentry` and `commit`
    /// to acoustics, that is, silently roll back the measurement, which cost a separate day.
    /// Details why these three: `DictionaryReplacement.noAcousticBoost`
    /// and docs/benchmarks.md.
    private static let unboostable: Set<String> = ["deploy", "Sentry", "commit"]
    /// These two phonetic keys collide with ordinary Russian words: “в центре”
    /// and “наблюдение комет”. Measured decoder spellings live as exact rules below.
    private static let nonPhonetic: Set<String> = ["Sentry", "commit"]

    /// The term in ordinary Russian writing - with all cases.
    ///
    /// These words in Russian speech are inclined: “before release”, “after deployment”,
    /// “no downtime”.
    ///
    /// What is intentionally missing here: substitutions that coincide with ordinary Russian
    /// in a word. “Python”, “radish”, “docker”, “brunch” have been removed from the set. Not from
    /// caution, but according to measurements: on recent recordings they did not work even once
    /// (0 out of 5 phrases for each term - the model writes “doper”, “cashverbis”,
    /// “written”), but they broke the usual speech: “the python squeezed its prey” turned into
    /// “Python compressed the loot”, “dockers unloaded the ship” - in “Docker unloaded
    /// ship." A person makes such a replacement for himself, consciously and for his own sake.
    /// dictionary; it has no place in the preparation.
    private static let inflecting: [(String, String)] = [
        // Working with code
        ("\u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}", "pull request"),
        ("\u{043F}\u{0438}\u{0430}\u{0440}", "PR"),
        ("\u{043C}\u{0451}\u{0440}\u{0434}\u{0436}", "merge"),
        ("\u{0440}\u{0435}\u{0431}\u{0435}\u{0439}\u{0437}", "rebase"),
        ("\u{0440}\u{0435}\u{0432}\u{044C}\u{044E}", "review"),
        ("\u{043A}\u{043E}\u{0434} \u{0440}\u{0435}\u{0432}\u{044C}\u{044E}", "code review"),

        // Launch and operation
        ("\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", "deploy"),
        ("\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}\u{043C}\u{0435}\u{043D}\u{0442}", "deployment"),
        ("\u{0431}\u{0438}\u{043B}\u{0434}", "build"),
        ("\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}", "release"),
        ("\u{0440}\u{043E}\u{043B}\u{043B}\u{0431}\u{044D}\u{043A}", "rollback"),
        ("\u{0434}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}", "downtime"),
        ("\u{043F}\u{0440}\u{043E}\u{0434}\u{0430}\u{043A}\u{0448}\u{043D}", "production"),
        ("\u{0441}\u{0442}\u{0435}\u{0439}\u{0434}\u{0436}\u{0438}\u{043D}\u{0433}", "staging"),

        // Tools
        ("\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}", "Sentry"),
        ("\u{0433}\u{0438}\u{0442}\u{0445}\u{0430}\u{0431}", "GitHub"),
        ("\u{043A}\u{0443}\u{0431}\u{0435}\u{0440}\u{043D}\u{0435}\u{0442}\u{0435}\u{0441}", "Kubernetes"),
        ("\u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0435}\u{0441}", "Postgres"),
        ("\u{043B}\u{0438}\u{043D}\u{0442}\u{0435}\u{0440}", "linter"),
        ("\u{044D}\u{043A}\u{0441} \u{043A}\u{043E}\u{0434}", "Xcode"),

        // Development
        ("\u{0444}\u{0438}\u{0447}\u{0430} \u{0444}\u{043B}\u{0430}\u{0433}", "feature flag"),
        ("\u{0445}\u{043E}\u{0442}\u{0444}\u{0438}\u{043A}\u{0441}", "hotfix"),
        ("\u{044D}\u{043D}\u{0434}\u{043F}\u{043E}\u{0438}\u{043D}\u{0442}", "endpoint"),
        ("\u{0430}\u{043F}\u{0438}", "API"),
        ("\u{0431}\u{044D}\u{043A}\u{0435}\u{043D}\u{0434}", "backend"),
        ("\u{0444}\u{0440}\u{043E}\u{043D}\u{0442}\u{0435}\u{043D}\u{0434}", "frontend"),
        ("\u{0442}\u{0430}\u{0439}\u{043F}\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}", "TypeScript"),
        ("\u{0434}\u{0436}\u{0430}\u{0432}\u{0430}\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}", "JavaScript"),
        ("\u{0441}\u{0432}\u{0438}\u{0444}\u{0442}", "Swift"),
    ]

    /// Substitutions that are taken only in the form in which they are written.
    ///
    /// Two reasons to come here, and both are verified by measurements.
    ///
    /// **This is not a word, but a recognition error.** Running fifteen phrases
    /// showed that the model hears “pul requist”, “github”, “postgriz”, “hod”
    /// fix"; The measurement is recorded in docs/benchmarks.md. The stump has no cases, and
    /// the inflected stem only invents coincidences for him. Checked: declination
    /// these entries did not add a single term to any entry in the corpus.
    ///
    /// **The base is the same as an ordinary Russian word.** So for “commit”: with
    /// up to unstressed vowels it is indistinguishable from a “comet”, and the inflected
    /// the basis of “comets-” turned “we looked at a comet” into “we looked at
    /// commit". The cost of failure is measured and small - one phrase out of thirty
    /// (“in commit” is no longer recognized), and fifteen ordinary Russians were saved
    /// words. The exact “коммит” and measured contextual decoder spellings are
    /// still repaired; broad phonetic matching is deliberately disabled.
    ///
    /// The second pass of the dictionary - phonetic - makes most of these entries
    /// unnecessary: “diploy” and “depla” are recognized from “deploy” themselves. Stayed here
    /// those that phonetics cannot reach.
    private static let literal: [(String, String)] = [
        ("\u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0438}\u{0441}\u{0442}", "pull request"),
        ("\u{043F}\u{0443}\u{043B}\u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}", "pull request"),
        ("\u{043C}\u{0435}\u{0440}\u{0434}\u{0436}", "merge"),
        ("\u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442}", "commit"),
        ("\u{0431}\u{0440}\u{0430}\u{043D}\u{043D}\u{0438}\u{0447}", "branch"),
        ("\u{0440}\u{0435}\u{0431}\u{0435}\u{0439}\u{0437}\u{043D}\u{0443}\u{0442}\u{044C}", "rebase"),
        ("\u{043A}\u{043E}\u{0442} \u{0440}\u{0435}\u{0432}\u{044C}\u{044E}", "code review"),
        ("\u{0440}\u{043E}\u{043B}\u{043B}\u{0431}\u{0443}\u{043A}", "rollback"),
        ("\u{0434}\u{043E}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}", "downtime"),
        ("\u{043F}\u{0440}\u{043E}\u{0434}\u{0430}\u{043A}\u{0448}", "production"),
        ("\u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}", "Sentry"),
        ("\u{0433}\u{0438}\u{0442}\u{0445}\u{0435}\u{0431}", "GitHub"),
        ("\u{043A}\u{0443}\u{0431}\u{0435}\u{0440}\u{043D}\u{0435}\u{0442}\u{0438}\u{0441}", "Kubernetes"),
        ("\u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0438}\u{0437}", "Postgres"),
        ("\u{043B}\u{0438}\u{043D}\u{0442}\u{0438}", "linter"),
        ("\u{0438}\u{043A}\u{0441}\u{043E}\u{0434}", "Xcode"),
        ("x-\u{043A}\u{043E}\u{0434}", "Xcode"),
        ("\u{0444}\u{0438}\u{0447}\u{0438}-\u{0444}\u{043B}\u{0430}\u{0433}", "feature flag"),
        ("\u{0445}\u{043E}\u{0434} \u{0444}\u{0438}\u{043A}\u{0441}", "hotfix"),
        ("\u{0431}\u{044D}\u{043A}\u{0438}\u{043D}\u{0433}", "backend"),
        ("\u{0444}\u{0440}\u{043E}\u{043D}\u{0442}\u{0438}\u{043D}\u{0433}", "frontend"),
        ("\u{0442}\u{0430}\u{0439}\u{043F}-\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}", "TypeScript"),
    ]

    /// Exact decoder errors that are specific enough to repair without changing
    /// ordinary Russian speech. Unlike the acoustic aliases above, these strings
    /// are never used to bias recognition.
    private static let postprocessingOnly: [(String, String)] = [
        ("\u{0444}\u{0438}\u{0447}\u{0435}\u{0440} \u{0444}\u{043B}\u{044D}\u{043A}", "feature flag"),
        ("\u{043A}\u{043E}\u{043C}\u{0438}\u{0442}", "commit"),
        // The model hears “commit в branch” as “эмит в branch”. A bare
        // “эмит” remains untouched because `emit` is a distinct developer term.
        ("\u{044D}\u{043C}\u{0438}\u{0442} \u{0432}", "commit \u{0432}"),
        ("\u{0431}\u{0440}\u{0430}\u{043D}\u{0434}\u{0436}", "branch"),
        ("\u{043F}\u{043E}\u{0435}\u{0437}\u{0434} \u{0433}\u{0435}\u{0440}\u{0437}", "Postgres"),
        ("\u{043A}\u{044D}\u{0448}\u{0432}\u{0435}\u{0440}\u{0431}\u{0438}\u{0441}", "\u{043A}\u{044D}\u{0448} \u{0432} Redis"),
        ("\u{043A}\u{044D}\u{0448}\u{0432}\u{0435}\u{0440}\u{0434}\u{0438}\u{0441}", "\u{043A}\u{044D}\u{0448} \u{0432} Redis"),
        ("\u{044D}\u{043A}\u{0441}\u{043A}\u{043E}\u{0443}\u{0442}", "Xcode"),
        ("\u{043A}\u{043E}\u{0443}\u{0442}\u{0440}\u{0438}\u{0432}\u{044C}\u{044E}", "code review"),
        ("\u{0434}\u{0430}\u{043A}\u{0430}\u{0440}\u{044B} \u{0432} \u{043A}\u{044C}\u{044E}\u{0431}\u{0435}\u{0440}\u{043D}\u{0438}\u{0446}", "Docker \u{0438} \u{0432} Kubernetes"),
        ("\u{0434}\u{0430}\u{043A}\u{0430}\u{0440}\u{0435}\u{0432}\u{043A}\u{0438} \u{0443}\u{0431}\u{0435}\u{0440}\u{043D}\u{0438}\u{0442}", "Docker \u{0438} Kubernetes"),
    ]

    /// Replacements that the user does not yet have.
    ///
    /// It is necessary that the “add set” sentence does not produce duplicates if
    /// the person has already created some of the terms himself.
    public static func missing(from existing: [DictionaryReplacement]) -> [DictionaryReplacement] {
        let known = Set(existing.map { $0.spoken.lowercased() })
        return developer.filter { !known.contains($0.spoken.lowercased()) }
    }
}
