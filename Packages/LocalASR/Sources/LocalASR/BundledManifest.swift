import DictationCore
import Foundation

extension ModelManifest {
    /// Manifest compiled into the application.
    ///
    /// This is the root of trust for the entire installation: file names, their sizes and control
    /// the amounts come from here, and the application signature excludes substitution.
    public static func bundled() throws -> ModelManifest {
        guard let url = Bundle.module.url(forResource: "model-manifest", withExtension: "json") else {
            throw ModelManifestError.resourceMissing
        }
        return try decode(from: LocalFile.read(url))
    }

    /// The model the current one replaced, kept in use on Macs that still
    /// hold it until the current model verifies. `nil` when a release has no
    /// predecessor to honor.
    public static func bundledPrevious() throws -> ModelManifest? {
        guard let url = Bundle.module.url(forResource: "previous-model-manifest", withExtension: "json") else {
            return nil
        }
        return try decode(from: LocalFile.read(url))
    }
}
