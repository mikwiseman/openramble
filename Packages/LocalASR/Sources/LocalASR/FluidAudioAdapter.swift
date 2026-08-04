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

    public func transcribe(samples: [Float]) async throws -> DictationCore.ASRResult {
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
            // language: nil — автоопределение. Модель покрывает 25 европейских
            // языков, и жёсткий выбор языка ломал бы смешанную речь.
            let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
            decoderState = state
            text = result.text
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

    public func unload() async {
        await manager?.cleanup()
        manager = nil
        models = nil
        decoderState = nil
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
