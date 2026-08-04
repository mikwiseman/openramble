import DictationCore
import Foundation

extension ModelManifest {
    /// Манифест, вкомпилированный в приложение.
    ///
    /// Это корень доверия ко всей установке: имена файлов, их размеры и контрольные
    /// суммы приходят отсюда, а подмену исключает подпись приложения.
    public static func bundled() throws -> ModelManifest {
        guard let url = Bundle.module.url(forResource: "model-manifest", withExtension: "json") else {
            throw ModelManifestError.resourceMissing
        }
        return try decode(from: LocalFile.read(url))
    }

    /// Манифест акустического подсказчика терминов (Parakeet CTC 110M).
    ///
    /// Отдельный файл, а не раздел основного: у модели свой репозиторий и своя
    /// ревизия, и жизненный цикл у неё собственный — установка, проверка и
    /// восстановление идут через тот же ModelStore, что и у основной.
    public static func bundledVocabulary() throws -> ModelManifest {
        guard
            let url = Bundle.module.url(forResource: "vocabulary-manifest", withExtension: "json")
        else {
            throw ModelManifestError.resourceMissing
        }
        return try decode(from: LocalFile.read(url))
    }
}
