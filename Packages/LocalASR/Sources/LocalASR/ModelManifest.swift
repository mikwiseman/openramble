import Foundation

/// Описание того, что именно скачивается для локального распознавания.
///
/// Манифест перечисляет **конкретные файлы**, а не папку целиком: репозиторий модели
/// на Hugging Face весит около 3 ГБ (там лежат ещё MelEncoder, EncoderInt4 и
/// JointDecisionv2, которые нам не нужны), тогда как рабочий набор — примерно 483 МБ.
///
/// Манифест вкомпилирован в приложение как ресурс. Доверие к нему обеспечивается
/// подписью самого приложения: подменить манифест, не сломав подпись, нельзя.
public struct ModelManifest: Codable, Sendable, Equatable {
    /// Один файл модели.
    public struct File: Codable, Sendable, Equatable {
        /// Путь внутри репозитория модели, он же путь внутри директории установки.
        public let path: String
        /// Ожидаемый размер. Проверяется до подсчёта контрольной суммы — это дёшево.
        public let byteCount: Int64
        /// SHA-256 в нижнем регистре. Единственная защита от повреждённой загрузки.
        public let sha256: String

        public init(path: String, byteCount: Int64, sha256: String) {
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    /// Идентификатор модели, он же имя директории установки.
    public let modelID: String
    /// Репозиторий Hugging Face.
    public let repository: String
    /// Неизменяемая ревизия. Никогда не `main`: содержимое ветки может измениться
    /// под нами, а мы обещаем воспроизводимость.
    public let revision: String
    /// Версия FluidAudio, с которой этот набор файлов проверен.
    public let fluidAudioVersion: String
    /// Квантизация — для честной атрибуции по CC BY 4.0.
    public let quantization: String
    /// Лицензия весов.
    public let license: String
    public let files: [File]
    /// Запасной источник. Может отсутствовать — тогда путь к модели один.
    public let mirror: Mirror?

    /// Второй адрес тех же файлов.
    ///
    /// Единственный источник — единственная точка отказа: репозиторий на
    /// Hugging Face могут удалить, переименовать или закрыть для целого региона,
    /// и тогда новый пользователь не запустит приложение вообще. Для проекта,
    /// который ставят и через год после релиза, это обычный сценарий.
    ///
    /// Запасной адрес ничего не ослабляет: доверие к файлам держится не на том,
    /// откуда они пришли, а на SHA-256 из этого же манифеста — они проверяются
    /// одинаково для любого источника.
    public struct Mirror: Codable, Sendable, Equatable {
        /// «владелец/репозиторий» на GitHub.
        public let repository: String
        /// Тег релиза, к которому приложены файлы.
        public let releaseTag: String

        public init(repository: String, releaseTag: String) {
            self.repository = repository
            self.releaseTag = releaseTag
        }

        /// Имя вложения релиза для файла модели.
        ///
        /// GitHub не разрешает косые черты в именах вложений, поэтому путь
        /// внутри модели уплощается. Разделитель двойной: одиночное
        /// подчёркивание встречается в самих именах файлов.
        ///
        /// Что выложить в релиз с тегом `releaseTag`: каждый файл манифеста
        /// отдельным вложением с этим именем. Например
        /// `Encoder.mlmodelc/weights/weight.bin` становится
        /// `Encoder.mlmodelc__weights__weight.bin`. Ни архивов, ни вложенных
        /// папок — приложение забирает файлы по одному и сверяет их суммы.
        public func assetName(for file: File) -> String {
            file.path.replacingOccurrences(of: "/", with: "__")
        }
    }

    public init(
        modelID: String,
        repository: String,
        revision: String,
        fluidAudioVersion: String,
        quantization: String,
        license: String,
        files: [File],
        mirror: Mirror? = nil
    ) {
        self.modelID = modelID
        self.repository = repository
        self.revision = revision
        self.fluidAudioVersion = fluidAudioVersion
        self.quantization = quantization
        self.license = license
        self.files = files
        self.mirror = mirror
    }

    /// Суммарный вес загрузки — показывается пользователю до нажатия кнопки.
    public var totalByteCount: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    /// Адрес файла на Hugging Face. Ревизия зафиксирована, поэтому ссылка неизменна.
    public func downloadURL(for file: File) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(file.path)"
        return components.url
    }

    /// Адрес того же файла в релизе на GitHub.
    public func mirrorURL(for file: File) -> URL? {
        guard let mirror else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(mirror.repository)/releases/download/\(mirror.releaseTag)/\(mirror.assetName(for: file))"
        return components.url
    }

    /// Все адреса файла в порядке обращения: сначала основной, потом запасной.
    public func downloadURLs(for file: File) -> [URL] {
        [downloadURL(for: file), mirrorURL(for: file)].compactMap { $0 }
    }
}

// MARK: - Загрузка вкомпилированного манифеста

public enum ModelManifestError: Error, Sendable, Equatable {
    case resourceMissing
    case malformed(String)
    case invalid(String)
}

extension ModelManifest {
    /// Разобрать манифест и убедиться, что он осмысленный.
    ///
    /// Проверки намеренно строгие: манифест — корень доверия ко всей установке,
    /// и лучше отказаться на старте, чем скачать 483 МБ и обнаружить проблему потом.
    public static func decode(from data: Data) throws -> ModelManifest {
        let manifest: ModelManifest
        do {
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            throw ModelManifestError.malformed(String(describing: error))
        }

        guard !manifest.files.isEmpty else {
            throw ModelManifestError.invalid("в манифесте нет ни одного файла")
        }
        // Ревизия обязана быть полным SHA коммита: короткая форма или имя ветки
        // не дают гарантии неизменности содержимого.
        guard manifest.revision.count == 40,
              manifest.revision.allSatisfy({ $0.isHexDigit })
        else {
            throw ModelManifestError.invalid("ревизия должна быть полным SHA-1 коммита")
        }
        for file in manifest.files {
            guard file.byteCount > 0 else {
                throw ModelManifestError.invalid("нулевой размер у \(file.path)")
            }
            guard file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw ModelManifestError.invalid("некорректная SHA-256 у \(file.path)")
            }
            // Путь приходит из манифеста и участвует в построении пути на диске,
            // поэтому выход за пределы директории установки должен быть невозможен.
            guard !file.path.hasPrefix("/"),
                  !file.path.contains(".."),
                  !file.path.isEmpty
            else {
                throw ModelManifestError.invalid("недопустимый путь: \(file.path)")
            }
        }

        if let mirror = manifest.mirror {
            // Запасной адрес — тоже корень доверия: из него строится URL,
            // и мусор в нём должен ловиться на старте, а не при отказе основного
            // источника, когда чинить уже некогда.
            let parts = mirror.repository.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
                throw ModelManifestError.invalid("запасной репозиторий должен быть «владелец/имя»")
            }
            guard !mirror.releaseTag.isEmpty else {
                throw ModelManifestError.invalid("у запасного источника пустой тег релиза")
            }
            guard manifest.files.allSatisfy({ manifest.mirrorURL(for: $0) != nil }) else {
                throw ModelManifestError.invalid("из запасного источника не строится адрес")
            }
        }
        return manifest
    }
}
