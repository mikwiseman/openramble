import DictationCore
import Foundation

/// Термины, которые распознавание должно узнавать на уровне звука.
///
/// Это не словарь замен: замены чинят текст после распознавания, а эти
/// термины уходят в акустический подсказчик (CTC keyword spotting) и меняют
/// сам результат. Тип живёт отдельно от FluidAudio, чтобы правила подготовки
/// списка проверялись без модели.
public struct VocabularyBoost: Sendable, Equatable {
    public struct Term: Sendable, Equatable {
        public let text: String
        /// Альтернативные написания того же термина — прежде всего
        /// кириллические: текст модели внутри русской фразы кириллический, и
        /// без такого моста кандидат на замену не находится вовсе.
        public let aliases: [String]

        /// Псевдонимы нормализуются как термины: пустое выбрасывается, края
        /// срезаются, дубликаты и совпадение с самим термином схлопываются.
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

    /// Насколько похоже слово в тексте должно быть на термин или псевдоним,
    /// чтобы претендовать на замену (0…1). Ниже — шире охват и больше ложных
    /// срабатываний на обычной речи; выше — осторожнее. Значение выбрано
    /// замером на корпусе: см. docs/benchmarks.md.
    public let minSimilarity: Float

    /// Насколько акустическая улика термина должна перевешивать исходное
    /// слово. Больше — замена агрессивнее; обычная русская речь, похожая на
    /// термин по звуку («в центре» и Sentry), страдает первой.
    public let biasWeight: Float

    public var isEmpty: Bool { terms.isEmpty }

    /// Пустые строки выбрасываются, пробелы по краям срезаются, дубликаты
    /// схлопываются без учёта регистра — побеждает первое написание: его
    /// человек ввёл сам.
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
    /// Термины, чьё кириллическое звучание — обычное русское слово. В
    /// акустический подсказчик они не идут вовсе: похожесть библиотеки видит
    /// сквозь алфавиты, а англоязычная CTC-модель всегда оценит латинский
    /// термин выше кириллического слова на той же записи. «Deploy» ловил
    /// «тёплой», «Sentry» — «в центре», «commit» — «комету»; хуже того,
    /// «центре» в честной русской фразе и «центре» на месте Sentry — один и
    /// тот же текст, и никакой порог их не разделит. Эти термины остаются
    /// словарю замен, чьи правила обычную речь не трогают (docs/benchmarks.md).
    static let unboostableWritten: Set<String> = ["deploy", "Sentry", "commit"]

    /// Набор по словарю пользователя: стартовые термины плюс его собственные
    /// замены — включая выученные из правок. Опасные термины отфильтрованы
    /// тем же правилом, что и в стартовом наборе: пользовательская запись
    /// «деплой → deploy» не имеет права вернуть deploy в акустику.
    public static func withUserReplacements(
        _ pairs: [(spoken: String, written: String)]
    ) -> VocabularyBoost {
        let defaults = developerDefault()
        let known = Set(defaults.terms.map { $0.text.lowercased() })
        let userTerms = pairs
            .filter { !unboostableWritten.contains($0.written) }
            .filter { $0.written.contains { $0.isLetter && $0.isASCII } }
            .filter { !known.contains($0.written.lowercased()) }
            .map { Term(text: $0.written, aliases: [$0.spoken]) }
        return VocabularyBoost(terms: defaults.terms + userTerms)
    }

    /// Готовый набор для словаря разработчика: латинский термин плюс его
    /// кириллические написания как псевдонимы — мост от звука к латинице.
    public static func developerDefault() -> VocabularyBoost {
        let grouped = Dictionary(grouping: StarterDictionary.developer, by: \.written)
        return VocabularyBoost(
            terms: grouped
                .filter { !unboostableWritten.contains($0.key) }
                .map { written, group in
                    Term(text: written, aliases: group.map(\.spoken))
                }
                .sorted { $0.text < $1.text }
        )
    }
}

/// Движок, умеющий показывать распознавание вживую, пока человек говорит.
///
/// Текст предпросмотра — только для глаз: источником истины остаётся
/// batch-распознавание готовой записи тем же движком.
public protocol LivePreviewCapable: Sendable {
    /// `confirmed` — устоявшийся текст, `volatile` — хвост, который ещё может
    /// поменяться. Обновления приходят не чаще четырёх раз в секунду: мерцание
    /// отвлекает сильнее, чем задержка.
    func startPreview(
        onUpdate: @escaping @Sendable (_ confirmed: String, _ volatile: String) -> Void
    ) async throws
    func feedPreview(samples: [Float]) async
    func stopPreview() async
}

extension FluidAudioAdapter: LivePreviewCapable {}

/// Движок, умеющий принимать акустические подсказки терминов.
///
/// Протокол живёт в LocalASR, а не в DictationCore: ядру диктовки безразлично,
/// откуда взялся текст, а способность «узнавать термины по звуку» — свойство
/// конкретного движка.
public protocol VocabularyBoostCapable: Sendable {
    func loadVocabularyModels(from directory: URL, boost: VocabularyBoost) async throws
}

extension FluidAudioAdapter: VocabularyBoostCapable {}
