import Foundation

/// Description of what exactly is downloaded for local recognition.
///
/// The manifest lists **specific files** rather than the entire folder: model repository
/// on Hugging Face weighs about 3 GB (there are also MelEncoder, EncoderInt4 and
/// JointDecisionv2, which we don't need), while the working set is approximately 483 MB.
///
/// The manifest is compiled into the application as a resource. Trust in him is ensured
/// with the signature of the application itself: it is impossible to replace the manifest without breaking the signature.
public struct ModelManifest: Codable, Sendable, Equatable {
    /// One model file.
    public struct File: Codable, Sendable, Equatable {
        /// The path inside the model repository, also the path inside the installation directory.
        public let path: String
        /// Expected size. It is checked before the checksum is calculated - it’s cheap.
        public let byteCount: Int64
        /// SHA-256 in lower case. The only protection against damaged downloads.
        public let sha256: String

        public init(path: String, byteCount: Int64, sha256: String) {
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    /// Model identifier, also known as the name of the installation directory.
    public let modelID: String
    /// Hugging Face repository.
    public let repository: String
    /// Immutable revision. Never `main`: the contents of the branch may change
    /// below us, and we promise reproducibility.
    public let revision: String
    /// The version of FluidAudio this set of files is tested against.
    public let fluidAudioVersion: String
    /// Quantization - for fair attribution according to CC BY 4.0.
    public let quantization: String
    /// Licensing scales.
    public let license: String
    public let files: [File]
    /// Spare source. It may be missing - then there is only one path to the model.
    public let mirror: Mirror?

    /// Second address of the same files.
    ///
    /// Single source - single point of failure: the repository on
    /// Hugging Face may be deleted, renamed or closed for an entire region,
    /// and then the new user will not launch the application at all. For the project,
    /// which is staged even a year after release, this is a common scenario.
    ///
    /// A spare address does not weaken anything: trust in files is not based on
    /// where they came from, and on SHA-256 from the same manifest - they are checked
    /// the same for any source.
    public struct Mirror: Codable, Sendable, Equatable {
        /// "owner/repository" on GitHub.
        public let repository: String
        /// Release tag to which the files are attached.
        public let releaseTag: String

        public init(repository: String, releaseTag: String) {
            self.repository = repository
            self.releaseTag = releaseTag
        }

        /// The name of the release attachment for the model file.
        ///
        /// GitHub doesn't allow forward slashes in attachment names, so the path
        /// flattened inside the model. Divider double: single
        /// Underscores appear in the file names themselves.
        ///
        /// What to put in a release with the `releaseTag` tag: each manifest file
        /// a separate attachment with this name. For example
        /// `Encoder.mlmodelc/weights/weight.bin` becomes
        /// `Encoder.mlmodelc__weights__weight.bin`. No archives, no attachments
        /// folders - the application takes files one by one and checks their totals.
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

    /// Total loading weight - shown to the user before pressing the button.
    public var totalByteCount: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    /// File address on Hugging Face. The revision is committed, so the link remains unchanged.
    public func downloadURL(for file: File) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(file.path)"
        return components.url
    }

    /// Address of the same file in the release on GitHub.
    public func mirrorURL(for file: File) -> URL? {
        guard let mirror else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(mirror.repository)/releases/download/\(mirror.releaseTag)/\(mirror.assetName(for: file))"
        return components.url
    }

    /// All file addresses are in the order of access: first the main one, then the backup one.
    /// The mirror leads, the origin backs it up.
    ///
    /// Both carry byte-identical, SHA-256-verified files, so the order is a
    /// pure speed choice: measured from a fast link, GitHub Releases served
    /// 11.4 MB/s against Hugging Face's 8.6 MB/s on the same 20 MB range, and
    /// the 445 MB encoder is most of the wait. A failure of either still falls
    /// through to the other.
    public func downloadURLs(for file: File) -> [URL] {
        [mirrorURL(for: file), downloadURL(for: file)].compactMap { $0 }
    }
}

// MARK: - Loading the compiled manifest

public enum ModelManifestError: Error, Sendable, Equatable {
    case resourceMissing
    case malformed(String)
    case invalid(String)
}

extension ModelManifest {
    /// Parse the manifest and make sure it makes sense.
    ///
    /// The checks are intentionally strict: the manifest is the root of trust in the entire installation,
    /// and it’s better to refuse at the start than to download 483 MB and discover the problem later.
    public static func decode(from data: Data) throws -> ModelManifest {
        let manifest: ModelManifest
        do {
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            throw ModelManifestError.malformed(String(describing: error))
        }

        guard !manifest.files.isEmpty else {
            throw ModelManifestError.invalid("the manifest lists no files")
        }
        // The revision must be the full SHA of the commit: short form or branch name
        // do not guarantee that the contents will not change.
        guard manifest.revision.count == 40,
              manifest.revision.allSatisfy({ $0.isHexDigit })
        else {
            throw ModelManifestError.invalid("the revision must be a full commit SHA-1")
        }
        for file in manifest.files {
            guard file.byteCount > 0 else {
                throw ModelManifestError.invalid("zero size for \(file.path)")
            }
            guard file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw ModelManifestError.invalid("invalid SHA-256 for \(file.path)")
            }
            // The path comes from the manifest and participates in constructing the path on the disk,
            // therefore leaving the installation directory should not be possible.
            guard !file.path.hasPrefix("/"),
                  !file.path.contains(".."),
                  !file.path.isEmpty
            else {
                throw ModelManifestError.invalid("invalid path: \(file.path)")
            }
        }

        if let mirror = manifest.mirror {
            // The backup address is also a root of trust: the URL is built from it,
            // and the garbage in it should be caught at the start, and not when the main one fails
            // source, when there is no time to repair.
            let parts = mirror.repository.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
                throw ModelManifestError.invalid("the mirror repository must be “owner/name”")
            }
            guard !mirror.releaseTag.isEmpty else {
                throw ModelManifestError.invalid("the mirror has an empty release tag")
            }
            guard manifest.files.allSatisfy({ manifest.mirrorURL(for: $0) != nil }) else {
                throw ModelManifestError.invalid("couldn't build a URL from the mirror")
            }
        }
        return manifest
    }
}
