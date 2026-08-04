import DictationCore
import FluidAudio
import Foundation

/// Единственное место во всём проекте, где импортируется FluidAudio.
///
/// Всё остальное — включая контроллер диктовки и его тесты — работает через
/// `ASREngineAdapting` из DictationCore. Если API библиотеки поедет (а её
/// документация местами расходится с тегом), чинить придётся только этот файл.
public actor FluidAudioAdapter: ASREngineAdapting {
    private var models: AsrModels?
    private var manager: AsrManager?

    // Акустический подсказчик терминов: CTC-модель ищет термины в звуке,
    // rescorer правит текст TDT по её уликам. Всё опционально: без явной
    // загрузки распознавание работает ровно как раньше.
    private var keywordSpotter: CtcKeywordSpotter?
    private var vocabularyRescorer: VocabularyRescorer?
    private var vocabularyContext: CustomVocabularyContext?
    private var vocabularySizeConfig: ContextBiasingConstants.VocabSizeConfig?
    private var vocabularyBiasWeight: Float?

    /// Состояние декодера TDT.
    ///
    /// Библиотека требует его как `inout` и переиспользует между вызовами для
    /// потокового режима. У нас режим другой: каждая диктовка самостоятельна,
    /// поэтому состояние создаётся заново перед каждым распознаванием — иначе
    /// хвост предыдущей фразы протёк бы в следующую. Создание может бросить
    /// ошибку, поэтому хранится опционально.
    private var decoderState: TdtDecoderState?

    /// Приклеивать ли 80 мс предыдущего окна к следующему.
    ///
    /// У библиотеки этот флаг включён по умолчанию: на английской речи он лечит
    /// пустые предсказания на стыке окон. На многоязычной v3 он делает обратное,
    /// и об этом написано в самой библиотеке (issue #594): сдвиг распределения
    /// первого кадра уводит декодер к английскому приору, и текст на стыке
    /// **молча пропадает**.
    ///
    /// Здесь он выключен, потому что это измерено: на восьми записях с
    /// переключением языка внутри фразы включённый флаг съедал 47 слов из 1038,
    /// выключенный — 17. Обрыв виден в тексте буквально: «The recovery pass
    /// reads.» — и конец предложения исчезает без ошибки. Параметр оставлен,
    /// чтобы замер можно было повторить (`WAI_ASR_MEL_CONTEXT` в asr-bench).
    private let melChunkContext: Bool

    public init(melChunkContext: Bool = false) {
        self.melChunkContext = melChunkContext
    }

    /// Для теста, который сторожит выбранное значение флага.
    var usesMelChunkContext: Bool { melChunkContext }

    /// Загрузить модель из подготовленной директории.
    ///
    /// Сети здесь нет: `AsrModels.load(from:)` читает уже разложенные бандлы.
    /// Это подтверждено документацией библиотеки (Documentation/ASR/ManualModelLoading.md)
    /// и проверяется отдельным прогоном в песочнице с запрещённой сетью.
    public func loadModels(from directory: URL) async throws {
        // Wai Dictation управляет моделью самостоятельно: пользователь явно
        // скачивает зафиксированный manifest, после чего каждый файл проверяется
        // по SHA-256. FluidAudio не должен пытаться «починить» повреждение своей
        // сетевой загрузкой. Флаг ставится здесь — на единственной границе импорта
        // FluidAudio — до любого loader во всех клиентах LocalASR, включая bench.
        ModelHub.offlineMode = true
        guard models == nil else { return }

        guard AsrModels.modelsExist(at: directory, version: .v3) else {
            throw ASREngineError.modelsUnavailable(
                "в \(directory.lastPathComponent) нет полного набора бандлов Parakeet v3"
            )
        }

        do {
            // `encoderPrecision: .int8` — это имя варианта файла в терминах библиотеки
            // (Encoder.mlmodelc против EncoderInt4.mlmodelc), а не описание квантизации.
            // Фактически энкодер квантизован 6-битной палитрой — так и указано в
            // атрибуции лицензии CC BY.
            let loaded = try await AsrModels.load(
                from: directory,
                version: .v3,
                encoderPrecision: .int8
            )
            let manager = AsrManager(config: ASRConfig(melChunkContext: melChunkContext))
            try await manager.loadModels(loaded)

            self.models = loaded
            self.manager = manager
        } catch {
            throw ASREngineError.modelsUnavailable(error.localizedDescription)
        }
    }

    /// Test seam: подтверждает, что настройка принадлежит адаптеру, а не одному
    /// из вызывающих приложений. Не используйте её вместо `loadModels` в runtime.
    static func enforceOfflineMode() {
        ModelHub.offlineMode = true
    }

    /// Загрузить акустический подсказчик терминов из локальной директории.
    ///
    /// Сети здесь нет по той же схеме, что и у основной модели:
    /// `CtcModels.loadDirect(from:)` читает уже разложенные бандлы
    /// (MelSpectrogram.mlmodelc, AudioEncoder.mlmodelc, vocab.json) и падает,
    /// если их не хватает. Пустой список терминов — осознанное «выключено»:
    /// модели не грузятся, распознавание идёт как раньше.
    public func loadVocabularyModels(from directory: URL, boost: VocabularyBoost) async throws {
        ModelHub.offlineMode = true
        guard !boost.isEmpty else { return }
        guard keywordSpotter == nil else { return }

        do {
            let ctcModels = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
            let spotter = CtcKeywordSpotter(
                models: ctcModels,
                blankId: ctcModels.vocabulary.count
            )
            // Термин без CTC-токенов rescorer молча пропускает — токенизация
            // здесь обязательна, это и есть включение термина в подсказки.
            let tokenizer = try await CtcTokenizer.load(from: directory)
            var terms: [CustomVocabularyTerm] = []
            for (index, term) in boost.terms.enumerated() {
                let tokenIds = tokenizer.encode(term.text)
                guard !tokenIds.isEmpty else {
                    // Текст термина в ошибку не попадает намеренно: содержимое
                    // словаря — данные человека, как и текст диктовки.
                    throw ASREngineError.modelsUnavailable(
                        "термин №\(index + 1) не токенизируется подсказчиком"
                    )
                }
                terms.append(
                    CustomVocabularyTerm(
                        text: term.text,
                        aliases: term.aliases.isEmpty ? nil : term.aliases,
                        ctcTokenIds: tokenIds
                    )
                )
            }
            let context = CustomVocabularyContext(
                terms: terms,
                minSimilarity: boost.minSimilarity
            )
            // Акустический rescue-проход выключен намеренно: он заменяет слова
            // по одной акустической улике, минуя порог похожести, и на нашем
            // корпусе именно он превращал «в центре» в Sentry и «комету» в
            // commit. Сама библиотека рекомендует выключать его для коротких
            // словарей (#702, #724); наш — десятки терминов, не сотни.
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: context,
                config: VocabularyRescorer.Config(
                    spotterRescueMinSimilarity: 0.5,
                    spotterRescueMultiWordMinSimilarity: 0.5,
                    spotterRescueEnabled: false
                ),
                ctcModelDirectory: directory
            )
            keywordSpotter = spotter
            vocabularyRescorer = rescorer
            vocabularyContext = context
            vocabularySizeConfig = ContextBiasingConstants.rescorerConfig(
                forVocabSize: context.terms.count
            )
            vocabularyBiasWeight = boost.biasWeight
        } catch {
            throw ASREngineError.modelsUnavailable(error.localizedDescription)
        }
    }

    public func transcribe(samples: [Float]) async throws -> DictationCore.ASRResult {
        try await transcribe(samples: samples, languageHint: nil)
    }

    /// Языки, которые движок принимает как подсказку (BCP-47 коды).
    ///
    /// Список — свойство движка, а не продукта, поэтому живёт на единственной
    /// границе импорта FluidAudio. UI строит из него выбор языка.
    public static var supportedLanguageHints: [String] {
        Language.allCases.map(\.rawValue)
    }

    public func transcribe(
        samples: [Float],
        languageHint: String?
    ) async throws -> DictationCore.ASRResult {
        // Подсказка проверяется до всего остального: неизвестный код — ошибка
        // вызывающего, и она обязана быть видимой, а не молча стать «auto».
        let language: Language?
        if let languageHint {
            guard let parsed = Language(rawValue: languageHint) else {
                throw ASREngineError.inferenceFailed(
                    "unsupported language hint: \(languageHint)"
                )
            }
            language = parsed
        } else {
            language = nil
        }

        guard let manager else {
            throw ASREngineError.modelsNotLoaded
        }
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("пустой буфер")
        }

        let started = ContinuousClock.now
        // Длительность считаем сами: библиотека в этой версии возвращает ноль,
        // а от неё зависит показатель «во сколько раз быстрее реального времени».
        let audioDuration = Double(samples.count) / AudioFileReader.targetSampleRate
        let text: String
        let timings: [TokenTiming]?
        do {
            // Каждая диктовка независима — начинаем с чистого состояния декодера.
            var state = try TdtDecoderState()
            // nil — автоопределение по звуку. Модель покрывает 25 европейских
            // языков; жёсткий выбор ломает смешанную речь, поэтому подсказка —
            // только явный выбор человека, когда акцент уводит автоопределение.
            let result = try await manager.transcribe(
                samples,
                decoderState: &state,
                language: language
            )
            decoderState = state
            // Подсказчик правит текст по акустическим уликам CTC-модели.
            // Тайминги остаются от исходных токенов: замена слова не двигает
            // его место в записи, а потребителей пословных таймингов, которым
            // важна побуквенная точность заменённого слова, в продукте нет.
            text = try await rescoreWithVocabulary(
                text: result.text,
                timings: result.tokenTimings,
                samples: samples
            ) ?? result.text
            timings = result.tokenTimings
        } catch is CancellationError {
            throw ASREngineError.cancelled
        } catch {
            throw ASREngineError.inferenceFailed(error.localizedDescription)
        }
        let elapsed = started.duration(to: .now)

        return DictationCore.ASRResult(
            text: text,
            words: Self.words(from: timings),
            audioDuration: audioDuration,
            processingDuration: elapsed.seconds
        )
    }

    /// Поправить текст по акустическим уликам подсказчика.
    ///
    /// Возвращает `nil`, когда подсказчик не настроен или менять нечего.
    /// Ошибка CTC-inference при настроенном подсказчике — настоящая ошибка
    /// распознавания: человек включил термины и вправе знать, что они не
    /// сработали, а запись сохранится для Retry.
    private func rescoreWithVocabulary(
        text: String,
        timings: [TokenTiming]?,
        samples: [Float]
    ) async throws -> String? {
        guard let keywordSpotter, let vocabularyRescorer, let vocabularyContext else {
            return nil
        }
        guard let timings, !timings.isEmpty, !text.isEmpty else { return nil }

        let spotResult = try await keywordSpotter.spotKeywordsWithLogProbs(
            audioSamples: samples,
            customVocabulary: vocabularyContext,
            minScore: nil
        )
        // Пустые log-probs — это не сбой, а «звука меньше одного кадра»:
        // таким записям подсказывать нечего.
        guard !spotResult.logProbs.isEmpty else { return nil }

        let sizeConfig = vocabularySizeConfig
            ?? ContextBiasingConstants.rescorerConfig(forVocabSize: vocabularyContext.terms.count)
        let output = vocabularyRescorer.ctcTokenRescore(
            transcript: text,
            tokenTimings: timings,
            logProbs: spotResult.logProbs,
            frameDuration: spotResult.frameDuration,
            cbw: vocabularyBiasWeight ?? sizeConfig.cbw,
            marginSeconds: 0.5,
            minSimilarity: max(sizeConfig.minSimilarity, vocabularyContext.minSimilarity)
        )
        return output.wasModified ? output.text : nil
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
        models = nil
        decoderState = nil
        keywordSpotter = nil
        vocabularyRescorer = nil
        vocabularyContext = nil
        vocabularySizeConfig = nil
        vocabularyBiasWeight = nil
    }

    /// Склеить пословные тайминги из токенов.
    ///
    /// Parakeet отдаёт результат по токенам, а не по словам: подслова начинаются
    /// без ведущего пробела, поэтому граница слова — это токен, который таким
    /// пробелом начинается.
    static func words(from timings: [TokenTiming]?) -> [DictationCore.ASRResult.Word] {
        guard let timings, !timings.isEmpty else { return [] }

        var words: [DictationCore.ASRResult.Word] = []
        var current: (text: String, start: TimeInterval, end: TimeInterval, confidence: Double)?

        for timing in timings {
            // Библиотека отдаёт токены с ведущим "▁" либо с обычным пробелом —
            // и то, и другое означает начало нового слова.
            let raw = timing.token
            let startsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ")
            let cleaned = raw
                .replacingOccurrences(of: "▁", with: "")
                .trimmingCharacters(in: .whitespaces)

            if cleaned.isEmpty { continue }

            if startsWord, let pending = current {
                words.append(
                    .init(
                        text: pending.text,
                        start: pending.start,
                        end: pending.end,
                        confidence: pending.confidence
                    )
                )
                current = nil
            }

            if var pending = current {
                pending.text += cleaned
                pending.end = timing.endTime
                pending.confidence = min(pending.confidence, Double(timing.confidence))
                current = pending
            } else {
                current = (cleaned, timing.startTime, timing.endTime, Double(timing.confidence))
            }
        }

        if let pending = current {
            words.append(
                .init(
                    text: pending.text,
                    start: pending.start,
                    end: pending.end,
                    confidence: pending.confidence
                )
            )
        }
        return words
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
