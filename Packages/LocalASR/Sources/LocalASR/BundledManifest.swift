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
}
