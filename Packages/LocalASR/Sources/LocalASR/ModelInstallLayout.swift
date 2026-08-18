import Foundation

/// Layout of model files on disk.
///
/// Installation occurs through an intermediate directory: files are downloaded to staging,
/// are checked there and only then move to the final place alone
/// renaming. Half installation, which can be taken as working,
/// does not exist by construction.
public struct ModelInstallLayout: Sendable {
    /// Root: ~/Library/Application Support/OpenRamble/Models
    public let root: URL
    public let modelID: String
    public let revision: String

    public init(root: URL, modelID: String, revision: String, engineFolderName: String) {
        self.root = root
        self.modelID = modelID
        self.revision = revision
        self.engineFolderName = engineFolderName
    }

    public init(manifest: ModelManifest, root: URL? = nil) throws {
        let base: URL
        if let root {
            base = root
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            base = support.appending(path: "OpenRamble/Models", directoryHint: .isDirectory)
        }
        // The library gets the folder name from the repository name, discarding the suffix
        // "-coreml". Tested against tag code 0.15.5.
        let folder = (manifest.repository.split(separator: "/").last.map(String.init) ?? manifest.modelID)
            .replacingOccurrences(of: "-coreml", with: "")
        self.init(
            root: base,
            modelID: manifest.modelID,
            revision: manifest.revision,
            engineFolderName: folder
        )
    }

    /// Directory of a specific model.
    public var modelDirectory: URL {
        root.appending(path: modelID, directoryHint: .isDirectory)
    }

    /// The folder name required by FluidAudio.
    ///
    /// The library calculates the path as “parent of the passed directory + name
    /// repository", although its documentation promises that it is enough to pass
    /// folder with bundles. The discrepancy was checked on tag code 0.15.5, so
    /// the layout adapts to the actual behavior.
    public let engineFolderName: String

    /// Final installation location. There is a revision in the name, so change the revision
    /// does not spoil an already installed model and allows you to rollback.
    public var installedDirectory: URL {
        modelDirectory.appending(path: revision, directoryHint: .isDirectory)
    }

    /// Directory to be passed to FluidAudio.
    public var engineDirectory: URL {
        installedDirectory.appending(path: engineFolderName, directoryHint: .isDirectory)
    }

    /// Where to put files inside the intermediate installation directory.
    public func engineDirectory(inside staging: URL) -> URL {
        staging.appending(path: engineFolderName, directoryHint: .isDirectory)
    }

    /// Ready mark. Written last; its presence means that all files
    /// in place and verified.
    public var readyMarker: URL {
        installedDirectory.appending(path: ".ready.json", directoryHint: .notDirectory)
    }

    /// The last known working setting for the duration of crash-safe promotion.
    /// On normal completion, deleted; after the fall is used for
    /// recovery before the state is shown to the interface.
    public var backupDirectory: URL {
        modelDirectory.appending(path: ".backup-\(revision)", directoryHint: .isDirectory)
    }

    /// Directory for a specific installation attempt. Unique to two
    /// Parallel attempts did not trample each other.
    public func stagingDirectory(attempt: UUID) -> URL {
        modelDirectory.appending(path: ".staging-\(attempt.uuidString)", directoryHint: .isDirectory)
    }

    /// File path inside the installation directory.
    ///
    /// The path from the manifest has already been checked to be outside the directory, but here
    /// this is rechecked: too expensive a mistake to rely on
    /// one barrier.
    public func destination(for file: ModelManifest.File, inside directory: URL) throws -> URL {
        // The path itself from the manifest is checked, and not the result of gluing.
        //
        // The glued path would have to be brought to canonical form via
        // file system, but it responds differently for the existing one and another
        // not created: the first has “/tmp”, the second has “/private/tmp” - the same
        // location, different lines. The barrier began to depend on what already lay
        // on disk, and rejected perfectly legal files, breaking the installation
        // entirely. Relative path parsing does not depend on the disk at all.
        //
        // Exactly three things lead outside: "..", a leading slash, and an empty path.
        let components = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw ModelInstallError.unsafePath(file.path)
        }

        return components.reduce(directory) { partial, component in
            partial.appending(path: component, directoryHint: .notDirectory)
        }
    }
}

public enum ModelInstallError: Error, Sendable, Equatable {
    case unsafePath(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case promoteFailed(String)
}

// MARK: - Ready mark

/// Contents of `.ready.json`.
///
/// Stores exactly what is needed to understand: what is established corresponds to what
/// what we are expecting now. If the revision or version of FluidAudio is different -
/// the installation is considered unsuitable, and not “probably will do.”
public struct ModelReadyMarker: Codable, Sendable, Equatable {
    public struct InstalledFile: Codable, Sendable, Equatable {
        public let path: String
        public let byteCount: Int64
        public let modifiedAt: Date?

        public init(path: String, byteCount: Int64, modifiedAt: Date?) {
            self.path = path
            self.byteCount = byteCount
            self.modifiedAt = modifiedAt
        }
    }

    public let revision: String
    public let runtimeVersion: String
    public let fileCount: Int
    public let totalByteCount: Int64
    public let verifiedAt: Date
    /// Old marker files do not contain inventory. They are decoded but pass through
    /// full check once and rewritten in a new format.
    public let installedFiles: [InstalledFile]?

    public init(
        revision: String,
        runtimeVersion: String,
        fileCount: Int,
        totalByteCount: Int64,
        verifiedAt: Date,
        installedFiles: [InstalledFile]? = nil
    ) {
        self.revision = revision
        self.runtimeVersion = runtimeVersion
        self.fileCount = fileCount
        self.totalByteCount = totalByteCount
        self.verifiedAt = verifiedAt
        self.installedFiles = installedFiles
    }

    public init(
        manifest: ModelManifest,
        verifiedAt: Date,
        installedFiles: [InstalledFile]? = nil
    ) {
        self.init(
            revision: manifest.revision,
            runtimeVersion: manifest.runtimeVersion,
            fileCount: manifest.files.count,
            totalByteCount: manifest.totalByteCount,
            verifiedAt: verifiedAt,
            installedFiles: installedFiles
        )
    }

    /// Whether what is installed fully matches the current manifest.
    public func matches(_ manifest: ModelManifest) -> Bool {
        describesSameFiles(manifest) && runtimeVersion == manifest.runtimeVersion
    }

    /// Are these the same files that the manifest asks for.
    ///
    /// Separated from `matches` intentionally. FluidAudio version is an application property,
    /// and not weights: a library update that does not affect the model revision does not
    /// The files on the disk are not byte different. While this was one test,
    /// the dependency patch would mean “the model is damaged, download 483 MB” from
    /// each user - for the fact that we raised the version number.
    ///
    /// The revision is the main one: it is the fixed SHA of the model commit, and its
    /// a match means that exactly the same bytes are expected. Coincidence -
    /// a reason to double-check files using checksums, and not download again.
    public func describesSameFiles(_ manifest: ModelManifest) -> Bool {
        revision == manifest.revision
            && fileCount == manifest.files.count
            && totalByteCount == manifest.totalByteCount
    }
}
