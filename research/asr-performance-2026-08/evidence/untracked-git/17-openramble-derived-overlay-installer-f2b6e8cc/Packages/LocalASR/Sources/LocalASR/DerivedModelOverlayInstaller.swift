import CryptoKit
import Darwin
import Foundation

// MARK: - Signed manifest

/// Signed evidence produced by the offline overlay packer.
///
/// Operation indices are deliberately absent from identity. Static shapes may add or remove
/// shape-only operations, shifting every later index while leaving neural tensors unchanged.
/// The packer must map each blob reference through an exporter-provided semantic tensor name,
/// and record the generated operation/output names only as exact secondary evidence.
public struct DerivedModelGraphAttestation: Codable, Equatable, Sendable {
    public enum MappingMode: String, Codable, Equatable, Sendable {
        case semanticNameAndBlobReferenceV1
        /// Decodable only so validation can fail with a precise error for obsolete manifests.
        case indexZip
    }

    public enum TensorRole: String, Codable, Equatable, Sendable {
        case sharedFromSource
        case overlayPayload
    }

    public struct Graph: Codable, Equatable, Sendable {
        public let path: String
        public let byteCount: Int64
        public let sha256: String
        public let operationCount: Int
        public let blobReferenceCount: Int

        public init(
            path: String,
            byteCount: Int64,
            sha256: String,
            operationCount: Int,
            blobReferenceCount: Int
        ) {
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
            self.operationCount = operationCount
            self.blobReferenceCount = blobReferenceCount
        }
    }

    public struct BlobReference: Codable, Equatable, Sendable {
        public let functionName: String
        public let blockName: String
        public let operationType: String
        public let operationName: String
        public let outputName: String
        public let attributeName: String
        public let fileName: String
        public let offset: UInt64

        public init(
            functionName: String,
            blockName: String,
            operationType: String,
            operationName: String,
            outputName: String,
            attributeName: String,
            fileName: String,
            offset: UInt64
        ) {
            self.functionName = functionName
            self.blockName = blockName
            self.operationType = operationType
            self.operationName = operationName
            self.outputName = outputName
            self.attributeName = attributeName
            self.fileName = fileName
            self.offset = offset
        }

        fileprivate var identity: String {
            [functionName, blockName, operationType, operationName, outputName, attributeName]
                .joined(separator: "\u{1F}")
        }
    }

    public struct TensorMapping: Codable, Equatable, Sendable {
        /// Stable state-dict/exporter identity; never a position in the MIL operation array.
        public let semanticTensorName: String
        public let role: TensorRole
        public let dataType: String
        public let shape: [Int64]
        public let decodedByteCount: Int64
        /// SHA-256 over canonical little-endian decoded tensor bytes.
        public let decodedSHA256: String
        /// Reference in the independently exported static-shape graph.
        public let standaloneReference: BlobReference
        /// Reference in the final packed graph.
        public let packedReference: BlobReference
        /// Required only for tensors reused from the pinned shipping blob.
        public let shippingReference: BlobReference?

        public init(
            semanticTensorName: String,
            role: TensorRole,
            dataType: String,
            shape: [Int64],
            decodedByteCount: Int64,
            decodedSHA256: String,
            standaloneReference: BlobReference,
            packedReference: BlobReference,
            shippingReference: BlobReference?
        ) {
            self.semanticTensorName = semanticTensorName
            self.role = role
            self.dataType = dataType
            self.shape = shape
            self.decodedByteCount = decodedByteCount
            self.decodedSHA256 = decodedSHA256
            self.standaloneReference = standaloneReference
            self.packedReference = packedReference
            self.shippingReference = shippingReference
        }
    }

    public let mappingMode: MappingMode
    /// Relative compiled bundle containing the packed graph, for example `Encoder.mlmodelc`.
    public let modelBundlePath: String
    public let shippingGraph: Graph
    public let standaloneGraph: Graph
    public let packedGraph: Graph
    public let tensors: [TensorMapping]

    public init(
        mappingMode: MappingMode,
        modelBundlePath: String,
        shippingGraph: Graph,
        standaloneGraph: Graph,
        packedGraph: Graph,
        tensors: [TensorMapping]
    ) {
        self.mappingMode = mappingMode
        self.modelBundlePath = modelBundlePath
        self.shippingGraph = shippingGraph
        self.standaloneGraph = standaloneGraph
        self.packedGraph = packedGraph
        self.tensors = tensors
    }

    fileprivate func validated() throws -> Self {
        guard mappingMode == .semanticNameAndBlobReferenceV1 else {
            throw DerivedModelOverlayError.invalidGraphAttestation(
                "index-based operation mapping is forbidden")
        }
        try DerivedModelOverlayManifest.validatePath(modelBundlePath)
        for graph in [shippingGraph, standaloneGraph, packedGraph] {
            try DerivedModelOverlayManifest.validatePath(graph.path)
            guard graph.byteCount > 0, graph.operationCount > 0, graph.blobReferenceCount > 0 else {
                throw DerivedModelOverlayError.invalidGraphAttestation(
                    "invalid graph counts for \(graph.path)")
            }
            try DerivedModelOverlayManifest.validateLowerHex(
                graph.sha256,
                count: 64,
                field: "graph SHA-256 for \(graph.path)"
            )
        }
        guard !tensors.isEmpty else {
            throw DerivedModelOverlayError.invalidGraphAttestation("tensor mapping is empty")
        }
        guard standaloneGraph.blobReferenceCount == tensors.count,
            packedGraph.blobReferenceCount == tensors.count
        else {
            throw DerivedModelOverlayError.invalidGraphAttestation(
                "standalone/packed blob references are not covered exactly once"
            )
        }

        let semanticNames = tensors.map(\.semanticTensorName)
        let standaloneReferences = tensors.map(\.standaloneReference.identity)
        let packedReferences = tensors.map(\.packedReference.identity)
        guard Set(semanticNames).count == tensors.count,
            Set(standaloneReferences).count == tensors.count,
            Set(packedReferences).count == tensors.count
        else {
            throw DerivedModelOverlayError.invalidGraphAttestation(
                "tensor mapping is not one-to-one")
        }

        var shippingReferences = Set<String>()
        for tensor in tensors {
            guard !tensor.semanticTensorName.isEmpty,
                !tensor.dataType.isEmpty,
                !tensor.shape.isEmpty,
                tensor.shape.allSatisfy({ $0 > 0 }),
                tensor.decodedByteCount > 0
            else {
                throw DerivedModelOverlayError.invalidGraphAttestation(
                    "invalid tensor descriptor for \(tensor.semanticTensorName)"
                )
            }
            try DerivedModelOverlayManifest.validateLowerHex(
                tensor.decodedSHA256,
                count: 64,
                field: "decoded tensor SHA-256 for \(tensor.semanticTensorName)"
            )
            try Self.validateReference(tensor.standaloneReference)
            try Self.validateReference(tensor.packedReference)
            switch tensor.role {
            case .sharedFromSource:
                guard let shipping = tensor.shippingReference else {
                    throw DerivedModelOverlayError.invalidGraphAttestation(
                        "shared tensor lacks shipping reference: \(tensor.semanticTensorName)"
                    )
                }
                try Self.validateReference(shipping)
                guard shippingReferences.insert(shipping.identity).inserted else {
                    throw DerivedModelOverlayError.invalidGraphAttestation(
                        "shipping blob reference is mapped more than once"
                    )
                }
            case .overlayPayload:
                guard tensor.shippingReference == nil else {
                    throw DerivedModelOverlayError.invalidGraphAttestation(
                        "overlay-only tensor unexpectedly has a shipping reference"
                    )
                }
            }
        }
        guard shippingReferences.count <= shippingGraph.blobReferenceCount else {
            throw DerivedModelOverlayError.invalidGraphAttestation(
                "mapped shipping references exceed the shipping graph"
            )
        }
        return self
    }

    fileprivate func manifestPath(for reference: BlobReference) throws -> String {
        let prefix = "@model_path/"
        guard reference.fileName.hasPrefix(prefix) else {
            throw DerivedModelOverlayError.invalidGraphAttestation(
                "invalid model-relative blob path")
        }
        let suffix = String(reference.fileName.dropFirst(prefix.count))
        let path = "\(modelBundlePath)/\(suffix)"
        try DerivedModelOverlayManifest.validatePath(path)
        return path
    }

    private static func validateReference(_ reference: BlobReference) throws {
        guard !reference.functionName.isEmpty,
            !reference.blockName.isEmpty,
            !reference.operationType.isEmpty,
            !reference.operationName.isEmpty,
            !reference.outputName.isEmpty,
            !reference.attributeName.isEmpty,
            reference.fileName.hasPrefix("@model_path/weights/"),
            !reference.fileName.contains("..")
        else {
            throw DerivedModelOverlayError.invalidGraphAttestation("invalid MIL blob reference")
        }
    }
}

/// A small, signed description of files derived from an already installed model.
///
/// The overlay is a cache, not an independent model. `source` pins the immutable
/// upstream manifest, while every shared file pins the exact bytes that may be
/// hard-linked into the derived tree.
public struct DerivedModelOverlayManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let byteCount: Int64
        public let sha256: String

        public init(path: String, byteCount: Int64, sha256: String) {
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public struct SharedFile: Codable, Equatable, Sendable {
        public let sourcePath: String
        public let destinationPath: String
        public let byteCount: Int64
        public let sha256: String

        public init(sourcePath: String, destinationPath: String, byteCount: Int64, sha256: String) {
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public struct Source: Codable, Equatable, Sendable {
        public let modelID: String
        public let revision: String
        public let engineFolderName: String
        /// SHA-256 of the exact encoded upstream manifest supplied to the installer.
        public let manifestSHA256: String

        public init(
            modelID: String, revision: String, engineFolderName: String, manifestSHA256: String
        ) {
            self.modelID = modelID
            self.revision = revision
            self.engineFolderName = engineFolderName
            self.manifestSHA256 = manifestSHA256
        }
    }

    public let schemaVersion: Int
    public let overlayID: String
    /// Content/build identifier for the complete derived program, represented as SHA-256.
    public let overlayRevision: String
    public let engineFolderName: String
    /// Exact FluidAudio source revision used for export/runtime validation.
    public let fluidAudioRevision: String
    public let source: Source
    /// Offline proof that every tensor/blob rewrite used semantic identity, not operation position.
    public let graphAttestations: [DerivedModelGraphAttestation]
    /// Bytes fetched for the overlay. Paths are relative to both payload and derived engine roots.
    public let payloadFiles: [File]
    /// Bytes reused from the source model, preferably by hard link.
    public let sharedFiles: [SharedFile]

    public init(
        schemaVersion: Int,
        overlayID: String,
        overlayRevision: String,
        engineFolderName: String,
        fluidAudioRevision: String,
        source: Source,
        graphAttestations: [DerivedModelGraphAttestation],
        payloadFiles: [File],
        sharedFiles: [SharedFile]
    ) {
        self.schemaVersion = schemaVersion
        self.overlayID = overlayID
        self.overlayRevision = overlayRevision
        self.engineFolderName = engineFolderName
        self.fluidAudioRevision = fluidAudioRevision
        self.source = source
        self.graphAttestations = graphAttestations
        self.payloadFiles = payloadFiles
        self.sharedFiles = sharedFiles
    }

    public struct Accounting: Equatable, Sendable {
        public let downloadByteCount: Int64
        public let sharedLogicalByteCount: Int64

        public var installedLogicalByteCount: Int64 { downloadByteCount + sharedLogicalByteCount }
        public var incrementalBytesIfHardlinked: Int64 { downloadByteCount }
        public var incrementalBytesIfCopied: Int64 { installedLogicalByteCount }
    }

    public var accounting: Accounting {
        .init(
            downloadByteCount: payloadFiles.reduce(0) { $0 + $1.byteCount },
            sharedLogicalByteCount: sharedFiles.reduce(0) { $0 + $1.byteCount }
        )
    }

    fileprivate func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw DerivedModelOverlayError.invalidManifest(
                "unsupported schema version \(schemaVersion)")
        }
        try Self.validateIdentifier(overlayID, field: "overlayID")
        try Self.validateIdentifier(source.modelID, field: "source.modelID")
        try Self.validateIdentifier(engineFolderName, field: "engineFolderName")
        try Self.validateIdentifier(source.engineFolderName, field: "source.engineFolderName")
        try Self.validateLowerHex(overlayRevision, count: 64, field: "overlayRevision")
        try Self.validateLowerHex(source.revision, count: 40, field: "source.revision")
        try Self.validateLowerHex(fluidAudioRevision, count: 40, field: "fluidAudioRevision")
        try Self.validateLowerHex(source.manifestSHA256, count: 64, field: "source.manifestSHA256")
        guard !payloadFiles.isEmpty else {
            throw DerivedModelOverlayError.invalidManifest("the overlay has no downloaded files")
        }
        guard !sharedFiles.isEmpty else {
            throw DerivedModelOverlayError.invalidManifest("the overlay has no source dependency")
        }
        guard !graphAttestations.isEmpty else {
            throw DerivedModelOverlayError.invalidGraphAttestation("graph attestation is missing")
        }
        for attestation in graphAttestations {
            _ = try attestation.validated()
        }

        for file in payloadFiles {
            try Self.validateFile(path: file.path, byteCount: file.byteCount, sha256: file.sha256)
        }
        for file in sharedFiles {
            try Self.validateFile(
                path: file.sourcePath, byteCount: file.byteCount, sha256: file.sha256)
            try Self.validatePath(file.destinationPath)
        }
        let destinations = payloadFiles.map(\.path) + sharedFiles.map(\.destinationPath)
        guard Set(destinations).count == destinations.count else {
            throw DerivedModelOverlayError.invalidManifest("duplicate derived destination path")
        }
        let payloadPaths = Set(payloadFiles.map(\.path))
        let sharedByDestination = Dictionary(
            uniqueKeysWithValues: sharedFiles.map { ($0.destinationPath, $0) }
        )
        for attestation in graphAttestations {
            guard
                let packedProgram = payloadFiles.first(where: {
                    $0.path == attestation.packedGraph.path
                }),
                packedProgram.byteCount == attestation.packedGraph.byteCount,
                packedProgram.sha256 == attestation.packedGraph.sha256
            else {
                throw DerivedModelOverlayError.invalidGraphAttestation(
                    "packed graph is not pinned by payload files"
                )
            }
            for tensor in attestation.tensors {
                let packedPath = try attestation.manifestPath(for: tensor.packedReference)
                switch tensor.role {
                case .sharedFromSource:
                    guard let shippingReference = tensor.shippingReference,
                        let shared = sharedByDestination[packedPath],
                        try attestation.manifestPath(for: shippingReference) == shared.sourcePath
                    else {
                        throw DerivedModelOverlayError.invalidGraphAttestation(
                            "shared tensor blob path is not pinned by sharedFiles"
                        )
                    }
                case .overlayPayload:
                    guard payloadPaths.contains(packedPath) else {
                        throw DerivedModelOverlayError.invalidGraphAttestation(
                            "overlay tensor blob path is not pinned by payloadFiles"
                        )
                    }
                }
            }
        }
        return self
    }

    fileprivate static func validateFile(path: String, byteCount: Int64, sha256: String) throws {
        try validatePath(path)
        guard byteCount > 0 else {
            throw DerivedModelOverlayError.invalidManifest("zero size for \(path)")
        }
        try validateLowerHex(sha256, count: 64, field: "SHA-256 for \(path)")
    }

    fileprivate static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
            !path.hasPrefix("/"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw DerivedModelOverlayError.invalidManifest("unsafe path: \(path)")
        }
    }

    private static func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty,
            !value.contains("/"),
            value != ".",
            value != ".."
        else {
            throw DerivedModelOverlayError.invalidManifest("invalid \(field)")
        }
    }

    fileprivate static func validateLowerHex(_ value: String, count: Int, field: String) throws {
        guard value.count == count,
            value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw DerivedModelOverlayError.invalidManifest("invalid \(field)")
        }
    }
}

public struct VerifiedDerivedModelOverlayManifest: Sendable {
    public let manifest: DerivedModelOverlayManifest
    public let envelopeSHA256: String
    public let signingKeyID: String

    fileprivate init(
        manifest: DerivedModelOverlayManifest, envelopeSHA256: String, signingKeyID: String
    ) {
        self.manifest = manifest
        self.envelopeSHA256 = envelopeSHA256
        self.signingKeyID = signingKeyID
    }
}

public enum DerivedModelOverlayEnvelope {
    private struct WireEnvelope: Codable {
        let keyID: String
        let manifest: DerivedModelOverlayManifest
        let signature: String
    }

    /// Verify both distribution identity (signature) and the exact catalog-pinned envelope bytes.
    public static func verify(
        _ data: Data,
        expectedEnvelopeSHA256: String,
        trustedKeys: [String: Data]
    ) throws -> VerifiedDerivedModelOverlayManifest {
        guard sha256(data) == expectedEnvelopeSHA256 else {
            throw DerivedModelOverlayError.envelopeHashMismatch
        }
        let envelope: WireEnvelope
        do {
            envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            throw DerivedModelOverlayError.invalidEnvelope(String(describing: error))
        }
        let manifest = try envelope.manifest.validated()
        guard let keyBytes = trustedKeys[envelope.keyID] else {
            throw DerivedModelOverlayError.untrustedSigningKey(envelope.keyID)
        }
        guard let signature = Data(base64Encoded: envelope.signature) else {
            throw DerivedModelOverlayError.invalidSignature
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try .init(rawRepresentation: keyBytes)
        } catch {
            throw DerivedModelOverlayError.invalidSignature
        }
        guard publicKey.isValidSignature(signature, for: try canonicalData(manifest)) else {
            throw DerivedModelOverlayError.invalidSignature
        }
        return .init(
            manifest: manifest,
            envelopeSHA256: expectedEnvelopeSHA256,
            signingKeyID: envelope.keyID
        )
    }

    static func signForTesting(
        manifest: DerivedModelOverlayManifest,
        keyID: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let manifest = try manifest.validated()
        let signature = try privateKey.signature(for: canonicalData(manifest))
        let envelope = WireEnvelope(
            keyID: keyID,
            manifest: manifest,
            signature: signature.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    fileprivate static func canonicalData(_ manifest: DerivedModelOverlayManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Layout and file identity

public struct DerivedModelOverlayLayout: Sendable {
    public let root: URL
    public let overlayID: String
    public let revision: String
    public let engineFolderName: String

    public init(root: URL, manifest: DerivedModelOverlayManifest) {
        self.root = root
        overlayID = manifest.overlayID
        revision = manifest.overlayRevision
        engineFolderName = manifest.engineFolderName
    }

    public var modelDirectory: URL {
        root.appending(path: overlayID, directoryHint: .isDirectory)
    }

    public var installedDirectory: URL {
        modelDirectory.appending(path: revision, directoryHint: .isDirectory)
    }

    public var engineDirectory: URL {
        installedDirectory.appending(path: engineFolderName, directoryHint: .isDirectory)
    }

    public var readyMarker: URL {
        installedDirectory.appending(
            path: ".derived-overlay-ready.json", directoryHint: .notDirectory)
    }

    public var backupDirectory: URL {
        modelDirectory.appending(path: ".overlay-backup-\(revision)", directoryHint: .isDirectory)
    }

    public func stagingDirectory(attempt: UUID) -> URL {
        modelDirectory.appending(
            path: ".overlay-staging-\(revision)-\(attempt.uuidString)",
            directoryHint: .isDirectory
        )
    }

    public func stagingDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: modelDirectory, includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(".overlay-staging-\(revision)-") }
    }

    fileprivate func engineDirectory(inside directory: URL) -> URL {
        directory.appending(path: engineFolderName, directoryHint: .isDirectory)
    }
}

public struct DerivedModelFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let linkCount: UInt64
    public let byteCount: Int64

    public static func read(_ url: URL) throws -> Self {
        var value = Darwin.stat()
        guard lstat(url.path, &value) == 0 else {
            throw DerivedModelOverlayError.io(
                "lstat \(url.path): \(String(cString: strerror(errno)))")
        }
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw DerivedModelOverlayError.notRegularFile(url.path)
        }
        return .init(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            linkCount: UInt64(value.st_nlink),
            byteCount: Int64(value.st_size)
        )
    }

    fileprivate static func device(of url: URL) throws -> UInt64 {
        var value = Darwin.stat()
        guard lstat(url.path, &value) == 0 else {
            throw DerivedModelOverlayError.io(
                "lstat \(url.path): \(String(cString: strerror(errno)))")
        }
        return UInt64(value.st_dev)
    }
}

// MARK: - Installer

public enum DerivedModelMaterialization: String, Codable, Equatable, Sendable {
    case payloadCopy
    case hardlink
    case clone
    case copy
}

/// System-call seam kept internal to the package; tests can deterministically exercise fallbacks.
struct DerivedModelMaterializationOperations: @unchecked Sendable {
    let hardlink: (URL, URL) throws -> Bool
    let clone: (URL, URL) throws -> Bool
    let copy: (URL, URL) throws -> Void

    static let system = Self(
        hardlink: { source, destination in
            Darwin.link(source.path, destination.path) == 0
        },
        clone: { source, destination in
            clonefile(source.path, destination.path, 0) == 0
        },
        copy: { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    )
}

public enum DerivedModelOverlayCheckpoint: String, Codable, CaseIterable, Equatable, Sendable {
    case afterStagingCreated
    case afterPayloadCopied
    case afterSharedMaterialized
    case afterReadyMarkerWritten
    case afterDestinationMovedToBackup
    case afterStagingPromoted
    case afterFinalVerified
    case beforeBackupRemoval
}

public enum DerivedModelOverlayError: Error, Equatable, Sendable {
    case envelopeHashMismatch
    case invalidEnvelope(String)
    case untrustedSigningKey(String)
    case invalidSignature
    case invalidManifest(String)
    case invalidGraphAttestation(String)
    case sourceManifestHashMismatch
    case sourceManifestMismatch(String)
    case sourceNotReady
    case featureDisabled
    case notRegularFile(String)
    case verificationFailed(String)
    case installedTreeInvalid(String)
    case io(String)
    case simulatedCrash(DerivedModelOverlayCheckpoint)
    case sourceHasDerivedOverlays([String])
}

public struct DerivedModelOverlayInstallReport: Equatable, Sendable {
    public let downloadByteCount: Int64
    public let installedLogicalByteCount: Int64
    public let materializations: [DerivedModelMaterialization]
    public let envelopeSHA256: String
}

private struct DerivedModelOverlayReadyMarker: Codable, Equatable {
    struct InstalledFile: Codable, Equatable {
        let path: String
        let byteCount: Int64
        let sha256: String
        let materialization: DerivedModelMaterialization
        let identity: DerivedModelFileIdentity
        let sourceIdentity: DerivedModelFileIdentity?
    }

    let schemaVersion: Int
    let overlayID: String
    let overlayRevision: String
    let envelopeSHA256: String
    let signingKeyID: String
    let source: DerivedModelOverlayManifest.Source
    let installedFiles: [InstalledFile]
}

/// Synchronous prototype. Product integration should wrap one instance in an actor so install,
/// reconcile and prune cannot overlap.
public final class DerivedModelOverlayInstaller {
    private let verified: VerifiedDerivedModelOverlayManifest
    private let layout: DerivedModelOverlayLayout
    private let fileManager: FileManager
    private let materialization: DerivedModelMaterializationOperations
    private let simulatedCrashAt: DerivedModelOverlayCheckpoint?
    private let verifier = ModelVerifier()

    public convenience init(manifest: VerifiedDerivedModelOverlayManifest, root: URL) {
        self.init(
            manifest: manifest,
            root: root,
            fileManager: .default,
            materialization: .system,
            simulatedCrashAt: nil
        )
    }

    init(
        manifest: VerifiedDerivedModelOverlayManifest,
        root: URL,
        fileManager: FileManager = .default,
        materialization: DerivedModelMaterializationOperations = .system,
        simulatedCrashAt: DerivedModelOverlayCheckpoint? = nil
    ) {
        verified = manifest
        layout = .init(root: root, manifest: manifest.manifest)
        self.fileManager = fileManager
        self.materialization = materialization
        self.simulatedCrashAt = simulatedCrashAt
    }

    /// Assemble and verify beside the destination, then publish with a single rename.
    @discardableResult
    public func install(
        payloadDirectory: URL,
        sourceManifestData: Data,
        featureEnabled: Bool,
        replaceExisting: Bool = false
    ) throws -> DerivedModelOverlayInstallReport {
        guard featureEnabled else { throw DerivedModelOverlayError.featureDisabled }
        let source = try validateSourceManifestAndFiles(sourceManifestData)
        try reconcile(sourceManifestData: sourceManifestData)

        if fileManager.fileExists(atPath: layout.installedDirectory.path), !replaceExisting {
            let marker = try validateCandidate(
                layout.installedDirectory,
                sourceManifest: source,
                requireSourceIdentity: true
            )
            return report(from: marker)
        }

        let staging = layout.stagingDirectory(attempt: UUID())
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try injectCrash(.afterStagingCreated)

            try collectPayload(from: payloadDirectory, into: staging)
            try injectCrash(.afterPayloadCopied)

            let sharedStrategies = try materializeSharedFiles(sourceManifest: source, into: staging)
            try injectCrash(.afterSharedMaterialized)

            // Both source and derived bytes are re-read after linking/copying. A source
            // mutation in the materialization window therefore cannot be blessed.
            _ = try validateSourceManifestAndFiles(sourceManifestData)
            let marker = try makeAndVerifyMarker(in: staging, sharedStrategies: sharedStrategies)
            try writeMarker(marker, in: staging)
            _ = try validateCandidate(staging, sourceManifest: source, requireSourceIdentity: true)
            try injectCrash(.afterReadyMarkerWritten)

            try promote(staging, sourceManifest: source)
            return report(from: marker)
        } catch let error as DerivedModelOverlayError {
            if case .simulatedCrash = error { throw error }
            try? reconcile(sourceManifestData: sourceManifestData)
            try? removeIfPresent(staging)
            throw error
        } catch {
            try? reconcile(sourceManifestData: sourceManifestData)
            try? removeIfPresent(staging)
            throw DerivedModelOverlayError.io(String(describing: error))
        }
    }

    /// Resolve every interrupted promotion state. A complete destination wins; otherwise
    /// a complete backup is restored. Staging is never made visible during recovery.
    public func reconcile(sourceManifestData: Data) throws {
        let sourceManifest = try validateSourceManifest(sourceManifestData)
        let destination = layout.installedDirectory
        let backup = layout.backupDirectory
        let destinationValid = candidateIsValid(destination, sourceManifest: sourceManifest)
        let backupValid = candidateIsValid(backup, sourceManifest: sourceManifest)

        if destinationValid {
            try removeIfPresent(backup)
        } else if backupValid {
            try removeIfPresent(destination)
            try fileManager.moveItem(at: backup, to: destination)
        } else {
            try removeIfPresent(destination)
            try removeIfPresent(backup)
        }
        for staging in try layout.stagingDirectories() {
            try removeIfPresent(staging)
        }
    }

    @discardableResult
    public func validateInstalled(sourceManifestData: Data) throws
        -> DerivedModelOverlayInstallReport
    {
        let source = try validateSourceManifestAndFiles(sourceManifestData)
        return report(
            from: try validateCandidate(
                layout.installedDirectory,
                sourceManifest: source,
                requireSourceIdentity: true
            ))
    }

    /// Feature rollback is cache-only: remove the derived revision and leave its source intact.
    public func rollbackForDisabledFeature(sourceManifestData: Data) throws {
        try reconcile(sourceManifestData: sourceManifestData)
        try removeIfPresent(layout.installedDirectory)
        try removeIfPresent(layout.backupDirectory)
        for staging in try layout.stagingDirectories() {
            try removeIfPresent(staging)
        }
    }

    private func promote(_ staging: URL, sourceManifest: ModelManifest) throws {
        try fileManager.createDirectory(
            at: layout.modelDirectory, withIntermediateDirectories: true)
        try removeIfPresent(layout.backupDirectory)
        if fileManager.fileExists(atPath: layout.installedDirectory.path) {
            try fileManager.moveItem(at: layout.installedDirectory, to: layout.backupDirectory)
        }
        try injectCrash(.afterDestinationMovedToBackup)
        try fileManager.moveItem(at: staging, to: layout.installedDirectory)
        try injectCrash(.afterStagingPromoted)
        _ = try validateCandidate(
            layout.installedDirectory,
            sourceManifest: sourceManifest,
            requireSourceIdentity: true
        )
        try injectCrash(.afterFinalVerified)
        try injectCrash(.beforeBackupRemoval)
        try removeIfPresent(layout.backupDirectory)
    }

    private func collectPayload(from payload: URL, into staging: URL) throws {
        let engine = layout.engineDirectory(inside: staging)
        for file in verified.manifest.payloadFiles {
            let source = try safeURL(relativePath: file.path, inside: payload)
            let destination = try safeURL(relativePath: file.path, inside: engine)
            _ = try DerivedModelFileIdentity.read(source)
            try verify(path: file.path, byteCount: file.byteCount, sha256: file.sha256, at: source)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            try verify(
                path: file.path, byteCount: file.byteCount, sha256: file.sha256, at: destination)
        }
    }

    private func materializeSharedFiles(
        sourceManifest: ModelManifest,
        into staging: URL
    ) throws -> [String: DerivedModelMaterialization] {
        let sourceLayout = sourceLayout(for: sourceManifest)
        let engine = layout.engineDirectory(inside: staging)
        var result: [String: DerivedModelMaterialization] = [:]
        for file in verified.manifest.sharedFiles {
            let source = try safeURL(
                relativePath: file.sourcePath, inside: sourceLayout.engineDirectory)
            let destination = try safeURL(relativePath: file.destinationPath, inside: engine)
            try verify(
                path: file.sourcePath, byteCount: file.byteCount, sha256: file.sha256, at: source)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            let sourceDevice = try DerivedModelFileIdentity.device(of: source)
            let destinationDevice = try DerivedModelFileIdentity.device(
                of: destination.deletingLastPathComponent())
            if sourceDevice == destinationDevice, try materialization.hardlink(source, destination)
            {
                result[file.destinationPath] = .hardlink
            } else if try materialization.clone(source, destination) {
                result[file.destinationPath] = .clone
            } else {
                try materialization.copy(source, destination)
                result[file.destinationPath] = .copy
            }
            try verify(
                path: file.destinationPath, byteCount: file.byteCount, sha256: file.sha256,
                at: destination)
        }
        return result
    }

    private func makeAndVerifyMarker(
        in directory: URL,
        sharedStrategies: [String: DerivedModelMaterialization]
    ) throws -> DerivedModelOverlayReadyMarker {
        let engine = layout.engineDirectory(inside: directory)
        var files: [DerivedModelOverlayReadyMarker.InstalledFile] = []
        for file in verified.manifest.payloadFiles {
            let url = try safeURL(relativePath: file.path, inside: engine)
            try verify(path: file.path, byteCount: file.byteCount, sha256: file.sha256, at: url)
            files.append(
                .init(
                    path: file.path,
                    byteCount: file.byteCount,
                    sha256: file.sha256,
                    materialization: .payloadCopy,
                    identity: try .read(url),
                    sourceIdentity: nil
                ))
        }
        let sourceLayout = ModelInstallLayout(
            root: layout.root,
            modelID: verified.manifest.source.modelID,
            revision: verified.manifest.source.revision,
            engineFolderName: verified.manifest.source.engineFolderName
        )
        for file in verified.manifest.sharedFiles {
            let url = try safeURL(relativePath: file.destinationPath, inside: engine)
            let sourceURL = try safeURL(
                relativePath: file.sourcePath, inside: sourceLayout.engineDirectory)
            let strategy = sharedStrategies[file.destinationPath] ?? .copy
            let identity = try DerivedModelFileIdentity.read(url)
            let sourceIdentity = try DerivedModelFileIdentity.read(sourceURL)
            if strategy == .hardlink,
                identity.device != sourceIdentity.device || identity.inode != sourceIdentity.inode
            {
                throw DerivedModelOverlayError.verificationFailed(
                    "hardlink identity mismatch for \(file.destinationPath)")
            }
            files.append(
                .init(
                    path: file.destinationPath,
                    byteCount: file.byteCount,
                    sha256: file.sha256,
                    materialization: strategy,
                    identity: identity,
                    sourceIdentity: sourceIdentity
                ))
        }
        return .init(
            schemaVersion: 1,
            overlayID: verified.manifest.overlayID,
            overlayRevision: verified.manifest.overlayRevision,
            envelopeSHA256: verified.envelopeSHA256,
            signingKeyID: verified.signingKeyID,
            source: verified.manifest.source,
            installedFiles: files.sorted { $0.path < $1.path }
        )
    }

    private func writeMarker(_ marker: DerivedModelOverlayReadyMarker, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let markerURL = directory.appending(path: ".derived-overlay-ready.json")
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }

    private func validateCandidate(
        _ directory: URL,
        sourceManifest: ModelManifest,
        requireSourceIdentity: Bool
    ) throws -> DerivedModelOverlayReadyMarker {
        let markerURL = directory.appending(path: ".derived-overlay-ready.json")
        guard fileManager.fileExists(atPath: markerURL.path) else {
            throw DerivedModelOverlayError.installedTreeInvalid("ready marker missing")
        }
        let marker: DerivedModelOverlayReadyMarker
        do {
            marker = try JSONDecoder().decode(
                DerivedModelOverlayReadyMarker.self,
                from: Data(contentsOf: markerURL)
            )
        } catch {
            throw DerivedModelOverlayError.installedTreeInvalid("ready marker damaged")
        }
        guard marker.schemaVersion == 1,
            marker.overlayID == verified.manifest.overlayID,
            marker.overlayRevision == verified.manifest.overlayRevision,
            marker.envelopeSHA256 == verified.envelopeSHA256,
            marker.signingKeyID == verified.signingKeyID,
            marker.source == verified.manifest.source
        else {
            throw DerivedModelOverlayError.installedTreeInvalid(
                "ready marker does not match signed manifest")
        }

        let engine = layout.engineDirectory(inside: directory)
        let rootEntries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard
            Set(rootEntries.map(\.lastPathComponent)) == [
                layout.engineFolderName, ".derived-overlay-ready.json",
            ]
        else {
            throw DerivedModelOverlayError.installedTreeInvalid(
                "unexpected file at overlay root")
        }
        let expectedFiles = Dictionary(
            uniqueKeysWithValues: marker.installedFiles.map { ($0.path, $0) })
        let actualPaths = try exactRegularFilePaths(inside: engine)
        guard actualPaths == Set(expectedFiles.keys) else {
            throw DerivedModelOverlayError.installedTreeInvalid(
                "installed inventory differs from marker")
        }
        let signedPaths = Set(
            verified.manifest.payloadFiles.map(\.path)
                + verified.manifest.sharedFiles.map(\.destinationPath))
        guard actualPaths == signedPaths else {
            throw DerivedModelOverlayError.installedTreeInvalid(
                "marker inventory differs from signed manifest")
        }

        let sourceLayout = sourceLayout(for: sourceManifest)
        for file in marker.installedFiles {
            let url = try safeURL(relativePath: file.path, inside: engine)
            try verify(path: file.path, byteCount: file.byteCount, sha256: file.sha256, at: url)
            let identity = try DerivedModelFileIdentity.read(url)
            guard identity.device == file.identity.device,
                identity.inode == file.identity.inode,
                identity.byteCount == file.identity.byteCount
            else {
                throw DerivedModelOverlayError.installedTreeInvalid(
                    "file identity changed for \(file.path)")
            }

            if file.materialization == .hardlink, requireSourceIdentity {
                guard
                    let shared = verified.manifest.sharedFiles.first(where: {
                        $0.destinationPath == file.path
                    })
                else {
                    throw DerivedModelOverlayError.installedTreeInvalid(
                        "hardlink has no signed source")
                }
                let sourceURL = try safeURL(
                    relativePath: shared.sourcePath, inside: sourceLayout.engineDirectory)
                let sourceIdentity = try DerivedModelFileIdentity.read(sourceURL)
                guard sourceIdentity.device == identity.device,
                    sourceIdentity.inode == identity.inode,
                    file.sourceIdentity?.device == sourceIdentity.device,
                    file.sourceIdentity?.inode == sourceIdentity.inode
                else {
                    throw DerivedModelOverlayError.installedTreeInvalid(
                        "source hardlink identity changed for \(file.path)")
                }
            }
        }
        return marker
    }

    private func validateSourceManifestAndFiles(_ data: Data) throws -> ModelManifest {
        let manifest = try validateSourceManifest(data)
        let sourceLayout = sourceLayout(for: manifest)
        guard fileManager.fileExists(atPath: sourceLayout.readyMarker.path),
            let marker = try? JSONDecoder().decode(
                ModelReadyMarker.self,
                from: Data(contentsOf: sourceLayout.readyMarker)
            ),
            marker.describesSameFiles(manifest)
        else {
            throw DerivedModelOverlayError.sourceNotReady
        }
        for shared in verified.manifest.sharedFiles {
            guard let sourceFile = manifest.files.first(where: { $0.path == shared.sourcePath }),
                sourceFile.byteCount == shared.byteCount,
                sourceFile.sha256 == shared.sha256
            else {
                throw DerivedModelOverlayError.sourceManifestMismatch(shared.sourcePath)
            }
            let url = try safeURL(
                relativePath: shared.sourcePath, inside: sourceLayout.engineDirectory)
            try verify(
                path: shared.sourcePath, byteCount: shared.byteCount, sha256: shared.sha256, at: url
            )
        }
        for attestation in verified.manifest.graphAttestations {
            let graph = attestation.shippingGraph
            guard let sourceFile = manifest.files.first(where: { $0.path == graph.path }),
                sourceFile.byteCount == graph.byteCount,
                sourceFile.sha256 == graph.sha256
            else {
                throw DerivedModelOverlayError.sourceManifestMismatch(
                    "shipping graph is not pinned: \(graph.path)")
            }
            let url = try safeURL(relativePath: graph.path, inside: sourceLayout.engineDirectory)
            try verify(
                path: graph.path,
                byteCount: graph.byteCount,
                sha256: graph.sha256,
                at: url
            )
        }
        return manifest
    }

    private func validateSourceManifest(_ data: Data) throws -> ModelManifest {
        guard DerivedModelOverlayEnvelope.sha256(data) == verified.manifest.source.manifestSHA256
        else {
            throw DerivedModelOverlayError.sourceManifestHashMismatch
        }
        let manifest: ModelManifest
        do {
            manifest = try ModelManifest.decode(from: data)
        } catch {
            throw DerivedModelOverlayError.sourceManifestMismatch(String(describing: error))
        }
        guard manifest.modelID == verified.manifest.source.modelID,
            manifest.revision == verified.manifest.source.revision
        else {
            throw DerivedModelOverlayError.sourceManifestMismatch(
                "model identity or revision differs")
        }
        return manifest
    }

    private func sourceLayout(for manifest: ModelManifest) -> ModelInstallLayout {
        .init(
            root: layout.root,
            modelID: manifest.modelID,
            revision: manifest.revision,
            engineFolderName: verified.manifest.source.engineFolderName
        )
    }

    private func candidateIsValid(_ directory: URL, sourceManifest: ModelManifest) -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        return
            (try? validateCandidate(
                directory,
                sourceManifest: sourceManifest,
                requireSourceIdentity: false
            )) != nil
    }

    private func exactRegularFilePaths(inside engine: URL) throws -> Set<String> {
        guard
            let enumerator = fileManager.enumerator(
                at: engine,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: []
            )
        else {
            throw DerivedModelOverlayError.installedTreeInvalid("engine directory missing")
        }
        let prefix = engine.standardizedFileURL.path + "/"
        var paths = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                throw DerivedModelOverlayError.installedTreeInvalid(
                    "symbolic link in installed tree")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw DerivedModelOverlayError.installedTreeInvalid(
                    "special file in installed tree")
            }
            let normalized = url.standardizedFileURL.path
            guard normalized.hasPrefix(prefix) else {
                throw DerivedModelOverlayError.installedTreeInvalid("file escaped engine directory")
            }
            paths.insert(String(normalized.dropFirst(prefix.count)))
        }
        return paths
    }

    private func verify(path: String, byteCount: Int64, sha256: String, at url: URL) throws {
        do {
            try verifier.verify(
                file: .init(path: path, byteCount: byteCount, sha256: sha256),
                at: url
            )
        } catch {
            throw DerivedModelOverlayError.verificationFailed(
                "\(path): \(String(describing: error))")
        }
    }

    private func safeURL(relativePath: String, inside directory: URL) throws -> URL {
        try DerivedModelOverlayManifest.validatePath(relativePath)
        return relativePath.split(separator: "/").reduce(directory) { partial, component in
            partial.appending(path: String(component), directoryHint: .notDirectory)
        }
    }

    private func report(from marker: DerivedModelOverlayReadyMarker)
        -> DerivedModelOverlayInstallReport
    {
        .init(
            downloadByteCount: verified.manifest.accounting.downloadByteCount,
            installedLogicalByteCount: verified.manifest.accounting.installedLogicalByteCount,
            materializations: marker.installedFiles
                .filter { $0.materialization != .payloadCopy }
                .map(\.materialization),
            envelopeSHA256: marker.envelopeSHA256
        )
    }

    private func injectCrash(_ checkpoint: DerivedModelOverlayCheckpoint) throws {
        if simulatedCrashAt == checkpoint {
            throw DerivedModelOverlayError.simulatedCrash(checkpoint)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

// MARK: - Dependency-aware pruning

public enum DerivedModelSourcePruneMode: Sendable {
    case refuseWhenDerivedExists
    case cascadeDerivedFirst
}

/// Scans ready markers rather than trusting caller bookkeeping. Each deletion is first renamed
/// to a hidden sibling tombstone, so a crash cannot expose a half-removed model directory.
public final class DerivedModelDependencyPruner {
    private let root: URL
    private let fileManager: FileManager
    private let onRemoval: ((URL) -> Void)?

    public convenience init(root: URL) {
        self.init(root: root, fileManager: .default, onRemoval: nil)
    }

    init(root: URL, fileManager: FileManager = .default, onRemoval: ((URL) -> Void)?) {
        self.root = root
        self.fileManager = fileManager
        self.onRemoval = onRemoval
    }

    public func pruneSource(modelID: String, revision: String, mode: DerivedModelSourcePruneMode)
        throws
    {
        try reconcileTombstones()
        let dependencies = try dependentInstallations(modelID: modelID, revision: revision)
        if !dependencies.isEmpty, mode == .refuseWhenDerivedExists {
            throw DerivedModelOverlayError.sourceHasDerivedOverlays(
                dependencies.map(\.overlayID).sorted())
        }
        if mode == .cascadeDerivedFirst {
            for dependency in dependencies.sorted(by: { $0.overlayID < $1.overlayID }) {
                try atomicallyRemove(dependency.directory)
            }
        }
        let source =
            root
            .appending(path: modelID, directoryHint: .isDirectory)
            .appending(path: revision, directoryHint: .isDirectory)
        try atomicallyRemove(source)
    }

    /// Finish housekeeping after a crash that occurred after an atomic prune rename.
    public func reconcileTombstones() throws {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)
        else {
            return
        }
        var tombstones: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix(".overlay-pruning-") {
            tombstones.append(url)
            enumerator.skipDescendants()
        }
        for tombstone in tombstones.sorted(by: { $0.path.count > $1.path.count }) {
            try fileManager.removeItem(at: tombstone)
        }
    }

    private func dependentInstallations(
        modelID: String,
        revision: String
    ) throws -> [(overlayID: String, directory: URL)] {
        guard
            let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else {
            return []
        }
        var result: [(String, URL)] = []
        for case let url as URL in enumerator
        where url.lastPathComponent == ".derived-overlay-ready.json" {
            guard let data = try? Data(contentsOf: url),
                let marker = try? JSONDecoder().decode(
                    DerivedModelOverlayReadyMarker.self, from: data),
                marker.source.modelID == modelID,
                marker.source.revision == revision
            else { continue }
            result.append((marker.overlayID, url.deletingLastPathComponent()))
        }
        return result
    }

    private func atomicallyRemove(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let tombstone = url.deletingLastPathComponent().appending(
            path: ".overlay-pruning-\(url.lastPathComponent)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.moveItem(at: url, to: tombstone)
        onRemoval?(url)
        try fileManager.removeItem(at: tombstone)
    }
}
