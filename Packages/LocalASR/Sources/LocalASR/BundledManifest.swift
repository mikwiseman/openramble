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

    /// Manifest of the acoustic term hinter (Parakeet CTC 110M).
    ///
    /// A separate file, not a section of the main one: the model has its own repository and its own
    /// revision, and it has its own life cycle - installation, verification and
    /// restoration goes through the same ModelStore as the main one.
    public static func bundledVocabulary() throws -> ModelManifest {
        guard
            let url = Bundle.module.url(forResource: "vocabulary-manifest", withExtension: "json")
        else {
            throw ModelManifestError.resourceMissing
        }
        return try decode(from: LocalFile.read(url))
    }
}
