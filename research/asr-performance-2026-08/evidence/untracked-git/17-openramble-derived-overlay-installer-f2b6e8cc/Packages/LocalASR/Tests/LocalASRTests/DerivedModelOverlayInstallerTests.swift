import CryptoKit
import Foundation
import XCTest

@testable import LocalASR

final class DerivedModelOverlayInstallerTests: XCTestCase {
    private var root: URL!
    private var payloadRoot: URL!

    private let sourceRevision = "aed02740059203c4a87495924f685de3722ae9ce"
    private let overlayRevision = "8a49e7b6744e8ebbe17c7318e287ec53cb82c265c18a81484a1352102faae027"
    private let weight = Data("shipping encoder weight".utf8)
    private let program = Data("short-shape program".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(
                path: "derived-overlay-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        payloadRoot = root.appending(path: "payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSignedEnvelopeRequiresPinnedBytesAndTrustedSignature() throws {
        let fixture = try makeFixture()

        let verified = try DerivedModelOverlayEnvelope.verify(
            fixture.envelopeData,
            expectedEnvelopeSHA256: fixture.envelopeSHA256,
            trustedKeys: [fixture.keyID: fixture.publicKey]
        )
        XCTAssertEqual(verified.manifest.source.revision, sourceRevision)
        XCTAssertEqual(verified.manifest.sharedFiles.first?.sha256, sha256(weight))

        XCTAssertThrowsError(
            try DerivedModelOverlayEnvelope.verify(
                fixture.envelopeData,
                expectedEnvelopeSHA256: String(repeating: "0", count: 64),
                trustedKeys: [fixture.keyID: fixture.publicKey]
            )
        ) { XCTAssertEqual($0 as? DerivedModelOverlayError, .envelopeHashMismatch) }

        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(
            try DerivedModelOverlayEnvelope.verify(
                fixture.envelopeData,
                expectedEnvelopeSHA256: fixture.envelopeSHA256,
                trustedKeys: [fixture.keyID: otherKey]
            )
        ) { XCTAssertEqual($0 as? DerivedModelOverlayError, .invalidSignature) }

        var changed = fixture.envelopeData
        changed.append(0x20)
        XCTAssertThrowsError(
            try DerivedModelOverlayEnvelope.verify(
                changed,
                expectedEnvelopeSHA256: fixture.envelopeSHA256,
                trustedKeys: [fixture.keyID: fixture.publicKey]
            )
        ) { XCTAssertEqual($0 as? DerivedModelOverlayError, .envelopeHashMismatch) }
    }

    func testGraphAttestationRejectsIndexZipAndIncompleteBlobCoverage() throws {
        let fixture = try makeFixture()
        let key = Curve25519.Signing.PrivateKey()

        for graph in [
            makeGraphAttestation(
                tensorSHA256: sha256(weight),
                tensorByteCount: Int64(weight.count),
                mappingMode: .indexZip
            ),
            makeGraphAttestation(
                tensorSHA256: sha256(weight),
                tensorByteCount: Int64(weight.count),
                packedBlobReferenceCount: 2
            ),
        ] {
            let invalid = DerivedModelOverlayManifest(
                schemaVersion: fixture.manifest.schemaVersion,
                overlayID: fixture.manifest.overlayID,
                overlayRevision: fixture.manifest.overlayRevision,
                engineFolderName: fixture.manifest.engineFolderName,
                fluidAudioRevision: fixture.manifest.fluidAudioRevision,
                source: fixture.manifest.source,
                graphAttestations: [graph],
                payloadFiles: fixture.manifest.payloadFiles,
                sharedFiles: fixture.manifest.sharedFiles
            )
            XCTAssertThrowsError(
                try DerivedModelOverlayEnvelope.signForTesting(
                    manifest: invalid,
                    keyID: "test",
                    privateKey: key
                )
            ) { error in
                guard case .invalidGraphAttestation = error as? DerivedModelOverlayError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testInstallHardlinksPinnedSourceAndAtomicallyPublishesVerifiedTree() throws {
        let fixture = try makeFixture()
        let installer = fixture.makeInstaller()

        let report = try installer.install(
            payloadDirectory: payloadRoot,
            sourceManifestData: fixture.sourceManifestData,
            featureEnabled: true
        )

        XCTAssertEqual(report.downloadByteCount, Int64(program.count))
        XCTAssertEqual(report.installedLogicalByteCount, Int64(program.count + weight.count))
        XCTAssertEqual(report.materializations, [.hardlink])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.readyMarker.path))

        let sourceIdentity = try DerivedModelFileIdentity.read(fixture.sourceWeightURL)
        let derivedIdentity = try DerivedModelFileIdentity.read(fixture.derivedWeightURL)
        XCTAssertEqual(derivedIdentity.device, sourceIdentity.device)
        XCTAssertEqual(derivedIdentity.inode, sourceIdentity.inode)
        XCTAssertGreaterThanOrEqual(derivedIdentity.linkCount, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.derivedProgramURL), program)
        XCTAssertNoThrow(
            try installer.validateInstalled(sourceManifestData: fixture.sourceManifestData))

        let entries = try exactRelativeFiles(in: fixture.layout.installedDirectory)
        XCTAssertEqual(
            entries,
            [
                ".derived-overlay-ready.json",
                "short-engine/Encoder.mlmodelc/program.mil",
                "short-engine/Encoder.mlmodelc/weights/weight.bin",
            ])
    }

    func testMaterializationFallsBackFromHardlinkToCloneThenCopy() throws {
        let cloneFixture = try makeFixture(subdirectory: "clone")
        let cloneOperations = DerivedModelMaterializationOperations(
            hardlink: { _, _ in false },
            clone: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                return true
            },
            copy: { _, _ in XCTFail("copy fallback should not run after a successful clone") }
        )
        let cloneInstaller = cloneFixture.makeInstaller(materialization: cloneOperations)
        let cloneReport = try cloneInstaller.install(
            payloadDirectory: cloneFixture.payloadRoot,
            sourceManifestData: cloneFixture.sourceManifestData,
            featureEnabled: true
        )
        XCTAssertEqual(cloneReport.materializations, [.clone])
        XCTAssertEqual(try Data(contentsOf: cloneFixture.derivedWeightURL), weight)

        let copyFixture = try makeFixture(subdirectory: "copy")
        var attempts: [String] = []
        let copyOperations = DerivedModelMaterializationOperations(
            hardlink: { _, _ in
                attempts.append("hardlink")
                return false
            },
            clone: { _, _ in
                attempts.append("clone")
                return false
            },
            copy: { source, destination in
                attempts.append("copy")
                try FileManager.default.copyItem(at: source, to: destination)
            }
        )
        let copyInstaller = copyFixture.makeInstaller(materialization: copyOperations)
        let copyReport = try copyInstaller.install(
            payloadDirectory: copyFixture.payloadRoot,
            sourceManifestData: copyFixture.sourceManifestData,
            featureEnabled: true
        )
        XCTAssertEqual(attempts, ["hardlink", "clone", "copy"])
        XCTAssertEqual(copyReport.materializations, [.copy])
        XCTAssertNotEqual(
            try DerivedModelFileIdentity.read(copyFixture.sourceWeightURL).inode,
            try DerivedModelFileIdentity.read(copyFixture.derivedWeightURL).inode
        )
    }

    func testActualAPFSClonefileFallbackCreatesDistinctInode() throws {
        let fixture = try makeFixture()
        let system = DerivedModelMaterializationOperations.system
        let operations = DerivedModelMaterializationOperations(
            hardlink: { _, _ in false },
            clone: system.clone,
            copy: system.copy
        )
        let report = try fixture.makeInstaller(materialization: operations).install(
            payloadDirectory: fixture.payloadRoot,
            sourceManifestData: fixture.sourceManifestData,
            featureEnabled: true
        )

        XCTAssertEqual(report.materializations, [.clone])
        XCTAssertNotEqual(
            try DerivedModelFileIdentity.read(fixture.sourceWeightURL).inode,
            try DerivedModelFileIdentity.read(fixture.derivedWeightURL).inode
        )
        XCTAssertEqual(try Data(contentsOf: fixture.derivedWeightURL), weight)
    }

    func testWrongSourceManifestOrMutatedWeightIsRejectedBeforeStagingBecomesVisible() throws {
        let fixture = try makeFixture()
        let installer = fixture.makeInstaller()

        var wrongManifestData = fixture.sourceManifestData
        wrongManifestData.append(0x20)
        XCTAssertThrowsError(
            try installer.install(
                payloadDirectory: payloadRoot,
                sourceManifestData: wrongManifestData,
                featureEnabled: true
            )
        ) { XCTAssertEqual($0 as? DerivedModelOverlayError, .sourceManifestHashMismatch) }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.installedDirectory.path))

        try Data(repeating: 0x78, count: weight.count).write(to: fixture.sourceWeightURL)
        XCTAssertThrowsError(
            try installer.install(
                payloadDirectory: payloadRoot,
                sourceManifestData: fixture.sourceManifestData,
                featureEnabled: true
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.installedDirectory.path))
    }

    func testCorruptPayloadLeavesNoPublishedOrStagingTree() throws {
        let fixture = try makeFixture()
        try Data(repeating: 0x66, count: program.count).write(
            to: fixture.payloadRoot.appending(
                path: "Encoder.mlmodelc/program.mil"
            ))

        XCTAssertThrowsError(
            try fixture.makeInstaller().install(
                payloadDirectory: fixture.payloadRoot,
                sourceManifestData: fixture.sourceManifestData,
                featureEnabled: true
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.installedDirectory.path))
        XCTAssertTrue(try fixture.layout.stagingDirectories().isEmpty)
    }

    func testValidationRejectsSameByteReplacementBecauseInodeChanged() throws {
        let fixture = try makeFixture()
        let installer = fixture.makeInstaller()
        _ = try installer.install(
            payloadDirectory: fixture.payloadRoot,
            sourceManifestData: fixture.sourceManifestData,
            featureEnabled: true
        )

        let replacement = fixture.derivedProgramURL.deletingLastPathComponent()
            .appending(path: "replacement.mil")
        try program.write(to: replacement)
        try FileManager.default.removeItem(at: fixture.derivedProgramURL)
        try FileManager.default.moveItem(at: replacement, to: fixture.derivedProgramURL)

        XCTAssertThrowsError(
            try installer.validateInstalled(sourceManifestData: fixture.sourceManifestData)
        ) {
            guard case .installedTreeInvalid = $0 as? DerivedModelOverlayError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testValidationRejectsUnexpectedFileOutsideEngine() throws {
        let fixture = try makeFixture()
        let installer = fixture.makeInstaller()
        _ = try installer.install(
            payloadDirectory: fixture.payloadRoot,
            sourceManifestData: fixture.sourceManifestData,
            featureEnabled: true
        )
        try Data("unexpected".utf8).write(
            to: fixture.layout.installedDirectory.appending(path: "unexpected.bin")
        )

        XCTAssertThrowsError(
            try installer.validateInstalled(sourceManifestData: fixture.sourceManifestData)
        ) {
            guard case .installedTreeInvalid = $0 as? DerivedModelOverlayError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testEveryCrashCheckpointReconcilesToACompleteOldOrNewInstall() throws {
        for checkpoint in DerivedModelOverlayCheckpoint.allCases {
            let fixture = try makeFixture(subdirectory: String(describing: checkpoint))
            let baseline = fixture.makeInstaller()
            _ = try baseline.install(
                payloadDirectory: fixture.payloadRoot,
                sourceManifestData: fixture.sourceManifestData,
                featureEnabled: true
            )

            let interrupted = fixture.makeInstaller(crashAt: checkpoint)
            XCTAssertThrowsError(
                try interrupted.install(
                    payloadDirectory: fixture.payloadRoot,
                    sourceManifestData: fixture.sourceManifestData,
                    featureEnabled: true,
                    replaceExisting: true
                )
            ) { error in
                XCTAssertEqual(error as? DerivedModelOverlayError, .simulatedCrash(checkpoint))
            }

            let relaunched = fixture.makeInstaller()
            try relaunched.reconcile(sourceManifestData: fixture.sourceManifestData)
            XCTAssertNoThrow(
                try relaunched.validateInstalled(sourceManifestData: fixture.sourceManifestData))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.layout.backupDirectory.path))
            XCTAssertTrue(try fixture.layout.stagingDirectories().isEmpty)
        }
    }

    func testFeatureFlagBlocksInstallAndRollbackRemovesOnlyDerivedLink() throws {
        let fixture = try makeFixture()
        let installer = fixture.makeInstaller()

        XCTAssertThrowsError(
            try installer.install(
                payloadDirectory: payloadRoot,
                sourceManifestData: fixture.sourceManifestData,
                featureEnabled: false
            )
        ) { XCTAssertEqual($0 as? DerivedModelOverlayError, .featureDisabled) }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.installedDirectory.path))

        _ = try installer.install(
            payloadDirectory: payloadRoot,
            sourceManifestData: fixture.sourceManifestData,
            featureEnabled: true
        )
        let sourceBefore = try DerivedModelFileIdentity.read(fixture.sourceWeightURL)
        try installer.rollbackForDisabledFeature(sourceManifestData: fixture.sourceManifestData)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.installedDirectory.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceWeightURL), weight)
        let sourceAfter = try DerivedModelFileIdentity.read(fixture.sourceWeightURL)
        XCTAssertEqual(sourceAfter.inode, sourceBefore.inode)
        XCTAssertEqual(sourceAfter.linkCount + 1, sourceBefore.linkCount)
    }

    func testDependencyPruneRefusesSourceOrDeletesDerivedBeforeSource() throws {
        let fixture = try makeFixture()
        _ = try fixture.makeInstaller().install(
            payloadDirectory: payloadRoot,
            sourceManifestData: fixture.sourceManifestData,
            featureEnabled: true
        )

        var removals: [URL] = []
        let pruner = DerivedModelDependencyPruner(root: fixture.modelsRoot) { removals.append($0) }
        XCTAssertThrowsError(
            try pruner.pruneSource(
                modelID: fixture.manifest.source.modelID,
                revision: fixture.manifest.source.revision,
                mode: .refuseWhenDerivedExists
            )
        ) { error in
            guard case .sourceHasDerivedOverlays(let ids) = error as? DerivedModelOverlayError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(ids, [fixture.manifest.overlayID])
        }

        try pruner.pruneSource(
            modelID: fixture.manifest.source.modelID,
            revision: fixture.manifest.source.revision,
            mode: .cascadeDerivedFirst
        )
        XCTAssertGreaterThanOrEqual(removals.count, 2)
        XCTAssertEqual(
            canonicalTemporaryPath(removals.first),
            canonicalTemporaryPath(fixture.layout.installedDirectory))
        XCTAssertEqual(
            canonicalTemporaryPath(removals.last),
            canonicalTemporaryPath(fixture.sourceLayout.installedDirectory))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.installedDirectory.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.sourceLayout.installedDirectory.path))
    }

    func testAccountingSeparatesDownloadLogicalAndWorstCasePhysicalBytes() throws {
        let fixture = try makeFixture()
        let accounting = fixture.manifest.accounting

        XCTAssertEqual(accounting.downloadByteCount, Int64(program.count))
        XCTAssertEqual(accounting.sharedLogicalByteCount, Int64(weight.count))
        XCTAssertEqual(accounting.installedLogicalByteCount, Int64(program.count + weight.count))
        XCTAssertEqual(accounting.incrementalBytesIfHardlinked, Int64(program.count))
        XCTAssertEqual(accounting.incrementalBytesIfCopied, Int64(program.count + weight.count))
    }

    func testPruneReconcileFinishesAtomicRenameTombstones() throws {
        let fixture = try makeFixture()
        let tombstone = fixture.modelsRoot.appending(
            path: ".overlay-pruning-crashed-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: tombstone, withIntermediateDirectories: true)
        try Data("partial cache".utf8).write(to: tombstone.appending(path: "file"))

        let pruner = DerivedModelDependencyPruner(root: fixture.modelsRoot)
        try pruner.reconcileTombstones()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
    }

    /// Opt-in, CPU-only scale smoke against the frozen compiled artifacts. It never loads Core ML.
    func testRealFrozenHybridOverlayWhenPathsAreProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let sourceManifestPath = environment["OPENRAMBLE_SOURCE_MANIFEST"],
            let sourceEnginePath = environment["OPENRAMBLE_SOURCE_ENGINE"],
            let hybridEnginePath = environment["OPENRAMBLE_HYBRID_ENGINE"]
        else {
            throw XCTSkip("real overlay paths were not provided")
        }

        let sourceManifestData = try Data(contentsOf: URL(fileURLWithPath: sourceManifestPath))
        let sourceManifest = try ModelManifest.decode(from: sourceManifestData)
        let modelsRoot = root.appending(path: "real-models", directoryHint: .isDirectory)
        let sourceLayout = ModelInstallLayout(
            root: modelsRoot,
            modelID: sourceManifest.modelID,
            revision: sourceManifest.revision,
            engineFolderName: "parakeet-tdt-0.6b-v3"
        )
        let sourceEngine = URL(fileURLWithPath: sourceEnginePath, isDirectory: true)
        for file in sourceManifest.files {
            let origin = sourceEngine.appending(path: file.path)
            let destination = sourceLayout.engineDirectory.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.linkItem(at: origin, to: destination)
        }
        let sourceMarker = ModelReadyMarker(
            manifest: sourceManifest, verifiedAt: Date(timeIntervalSince1970: 1))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(sourceMarker).write(to: sourceLayout.readyMarker, options: .atomic)

        let hybridEngine = URL(fileURLWithPath: hybridEnginePath, isDirectory: true)
        let payloadPaths = [
            "Encoder.mlmodelc/analytics/coremldata.bin",
            "Encoder.mlmodelc/coremldata.bin",
            "Encoder.mlmodelc/metadata.json",
            "Encoder.mlmodelc/model.mil",
            "Encoder.mlmodelc/weights/short-shape.bin",
            "Preprocessor.mlmodelc/analytics/coremldata.bin",
            "Preprocessor.mlmodelc/coremldata.bin",
            "Preprocessor.mlmodelc/metadata.json",
            "Preprocessor.mlmodelc/model.mil",
            "Preprocessor.mlmodelc/weights/weight.bin",
        ]
        let realPayload = root.appending(path: "real-payload", directoryHint: .isDirectory)
        let payloadFiles: [DerivedModelOverlayManifest.File] = try payloadPaths.map { path in
            let origin = hybridEngine.appending(path: path)
            let identity = try DerivedModelFileIdentity.read(origin)
            let destination = realPayload.appending(path: path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.linkItem(at: origin, to: destination)
            return .init(
                path: path,
                byteCount: identity.byteCount,
                sha256: try ModelVerifier().sha256(of: origin, path: path)
            )
        }

        let sharedFiles: [DerivedModelOverlayManifest.SharedFile] = sourceManifest.files.compactMap
        { file in
            if file.path == "Encoder.mlmodelc/weights/weight.bin" {
                return .init(
                    sourcePath: file.path,
                    destinationPath: "Encoder.mlmodelc/weights/shipping.bin",
                    byteCount: file.byteCount,
                    sha256: file.sha256
                )
            }
            guard
                file.path.hasPrefix("Decoder.mlmodelc/")
                    || file.path.hasPrefix("JointDecisionv3.mlmodelc/")
                    || file.path == "parakeet_vocab.json"
            else { return nil }
            return .init(
                sourcePath: file.path,
                destinationPath: file.path,
                byteCount: file.byteCount,
                sha256: file.sha256
            )
        }
        let overlayRevision = sha256(Data(payloadFiles.map(\.sha256).joined().utf8))
        let shippingWeight = try XCTUnwrap(
            sourceManifest.files.first { $0.path == "Encoder.mlmodelc/weights/weight.bin" }
        )
        let shippingGraph = try XCTUnwrap(
            sourceManifest.files.first { $0.path == "Encoder.mlmodelc/model.mil" }
        )
        let packedGraph = try XCTUnwrap(
            payloadFiles.first { $0.path == "Encoder.mlmodelc/model.mil" }
        )
        let manifest = DerivedModelOverlayManifest(
            schemaVersion: 1,
            overlayID: "short-shape-7_5-real-smoke",
            overlayRevision: overlayRevision,
            engineFolderName: "parakeet-tdt-0.6b-v3",
            fluidAudioRevision: "ee9a7f12d91710da53de6d75f8b7160e09eccee4",
            source: .init(
                modelID: sourceManifest.modelID,
                revision: sourceManifest.revision,
                engineFolderName: sourceLayout.engineFolderName,
                manifestSHA256: sha256(sourceManifestData)
            ),
            graphAttestations: [
                makeGraphAttestation(
                    tensorSHA256: shippingWeight.sha256,
                    tensorByteCount: shippingWeight.byteCount,
                    shippingGraphPath: shippingGraph.path,
                    shippingGraphByteCount: shippingGraph.byteCount,
                    shippingGraphSHA256: shippingGraph.sha256,
                    packedGraphPath: packedGraph.path,
                    packedGraphByteCount: packedGraph.byteCount,
                    packedGraphSHA256: packedGraph.sha256,
                    packedWeightFileName: "shipping.bin"
                )
            ],
            payloadFiles: payloadFiles,
            sharedFiles: sharedFiles
        )
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try DerivedModelOverlayEnvelope.signForTesting(
            manifest: manifest,
            keyID: "scale-smoke",
            privateKey: key
        )
        let verified = try DerivedModelOverlayEnvelope.verify(
            envelope,
            expectedEnvelopeSHA256: sha256(envelope),
            trustedKeys: ["scale-smoke": key.publicKey.rawRepresentation]
        )

        let installer = DerivedModelOverlayInstaller(manifest: verified, root: modelsRoot)
        let report = try installer.install(
            payloadDirectory: realPayload,
            sourceManifestData: sourceManifestData,
            featureEnabled: true
        )

        XCTAssertEqual(sourceManifest.revision, "aed02740059203c4a87495924f685de3722ae9ce")
        XCTAssertEqual(
            sha256(sourceManifestData),
            "05046d2b0b12fcfcf82625256bbf606eed198a064a73f979b5b2b3a617f0f78b")
        XCTAssertEqual(manifest.accounting.downloadByteCount, 4_679_628)
        XCTAssertEqual(manifest.accounting.sharedLogicalByteCount, 481_619_404)
        XCTAssertEqual(report.installedLogicalByteCount, 486_299_032)
        XCTAssertEqual(report.materializations, Array(repeating: .hardlink, count: 12))

        let installedLayout = DerivedModelOverlayLayout(root: modelsRoot, manifest: manifest)
        let sourceWeight = sourceLayout.engineDirectory.appending(
            path: "Encoder.mlmodelc/weights/weight.bin"
        )
        let installedWeight = installedLayout.engineDirectory.appending(
            path: "Encoder.mlmodelc/weights/shipping.bin"
        )
        XCTAssertEqual(
            try DerivedModelFileIdentity.read(sourceWeight).inode,
            try DerivedModelFileIdentity.read(installedWeight).inode)
        XCTAssertNoThrow(try installer.validateInstalled(sourceManifestData: sourceManifestData))
    }
}

extension DerivedModelOverlayInstallerTests {
    fileprivate struct Fixture {
        let modelsRoot: URL
        let payloadRoot: URL
        let manifest: DerivedModelOverlayManifest
        let verified: VerifiedDerivedModelOverlayManifest
        let sourceManifestData: Data
        let sourceLayout: ModelInstallLayout
        let layout: DerivedModelOverlayLayout
        let envelopeData: Data
        let envelopeSHA256: String
        let keyID: String
        let publicKey: Data

        var sourceWeightURL: URL {
            sourceLayout.engineDirectory.appending(path: "Encoder.mlmodelc/weights/weight.bin")
        }

        var derivedWeightURL: URL {
            layout.engineDirectory.appending(path: "Encoder.mlmodelc/weights/weight.bin")
        }

        var derivedProgramURL: URL {
            layout.engineDirectory.appending(path: "Encoder.mlmodelc/program.mil")
        }

        func makeInstaller(
            materialization: DerivedModelMaterializationOperations = .system,
            crashAt: DerivedModelOverlayCheckpoint? = nil
        ) -> DerivedModelOverlayInstaller {
            DerivedModelOverlayInstaller(
                manifest: verified,
                root: modelsRoot,
                materialization: materialization,
                simulatedCrashAt: crashAt
            )
        }
    }

    fileprivate func makeFixture(subdirectory: String? = nil) throws -> Fixture {
        let fixtureRoot: URL =
            subdirectory.map {
                root.appending(path: $0, directoryHint: .isDirectory)
            } ?? root
        let modelsRoot = fixtureRoot.appending(path: "models", directoryHint: .isDirectory)
        let localPayload = fixtureRoot.appending(path: "payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: localPayload, withIntermediateDirectories: true)

        let sourceManifest = ModelManifest(
            modelID: "shipping-model",
            repository: "FluidInference/shipping-coreml",
            revision: sourceRevision,
            fluidAudioVersion: "0.15.5",
            quantization: "6-bit",
            license: "CC-BY-4.0",
            files: [
                .init(
                    path: "Encoder.mlmodelc/weights/weight.bin",
                    byteCount: Int64(weight.count),
                    sha256: sha256(weight)
                ),
                .init(
                    path: "Encoder.mlmodelc/program.mil",
                    byteCount: Int64(program.count),
                    sha256: sha256(program)
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sourceManifestData = try encoder.encode(sourceManifest)
        let sourceLayout = ModelInstallLayout(
            root: modelsRoot,
            modelID: sourceManifest.modelID,
            revision: sourceManifest.revision,
            engineFolderName: "shipping"
        )
        let sourceWeightURL = sourceLayout.engineDirectory
            .appending(path: "Encoder.mlmodelc/weights/weight.bin")
        try FileManager.default.createDirectory(
            at: sourceWeightURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try weight.write(to: sourceWeightURL)
        let sourceProgramURL = sourceLayout.engineDirectory.appending(
            path: "Encoder.mlmodelc/program.mil"
        )
        try program.write(to: sourceProgramURL)
        let sourceMarker = ModelReadyMarker(
            manifest: sourceManifest, verifiedAt: Date(timeIntervalSince1970: 1))
        try encoder.encode(sourceMarker).write(to: sourceLayout.readyMarker, options: .atomic)

        let programFile = DerivedModelOverlayManifest.File(
            path: "Encoder.mlmodelc/program.mil",
            byteCount: Int64(program.count),
            sha256: sha256(program)
        )
        let payloadProgramURL = localPayload.appending(path: programFile.path)
        try FileManager.default.createDirectory(
            at: payloadProgramURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try program.write(to: payloadProgramURL)

        let manifest = DerivedModelOverlayManifest(
            schemaVersion: 1,
            overlayID: "short-shape-7_5",
            overlayRevision: overlayRevision,
            engineFolderName: "short-engine",
            fluidAudioRevision: "ee9a7f12d91710da53de6d75f8b7160e09eccee4",
            source: .init(
                modelID: sourceManifest.modelID,
                revision: sourceManifest.revision,
                engineFolderName: sourceLayout.engineFolderName,
                manifestSHA256: sha256(sourceManifestData)
            ),
            graphAttestations: [
                makeGraphAttestation(
                    tensorSHA256: sha256(weight),
                    tensorByteCount: Int64(weight.count)
                )
            ],
            payloadFiles: [programFile],
            sharedFiles: [
                .init(
                    sourcePath: "Encoder.mlmodelc/weights/weight.bin",
                    destinationPath: "Encoder.mlmodelc/weights/weight.bin",
                    byteCount: Int64(weight.count),
                    sha256: sha256(weight)
                )
            ]
        )

        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = "test-release-key"
        let envelopeData = try DerivedModelOverlayEnvelope.signForTesting(
            manifest: manifest,
            keyID: keyID,
            privateKey: privateKey
        )
        let envelopeSHA = sha256(envelopeData)
        let verified = try DerivedModelOverlayEnvelope.verify(
            envelopeData,
            expectedEnvelopeSHA256: envelopeSHA,
            trustedKeys: [keyID: privateKey.publicKey.rawRepresentation]
        )
        let layout = DerivedModelOverlayLayout(root: modelsRoot, manifest: manifest)
        return Fixture(
            modelsRoot: modelsRoot,
            payloadRoot: localPayload,
            manifest: manifest,
            verified: verified,
            sourceManifestData: sourceManifestData,
            sourceLayout: sourceLayout,
            layout: layout,
            envelopeData: envelopeData,
            envelopeSHA256: envelopeSHA,
            keyID: keyID,
            publicKey: privateKey.publicKey.rawRepresentation
        )
    }

    fileprivate func makeGraphAttestation(
        tensorSHA256: String,
        tensorByteCount: Int64,
        mappingMode: DerivedModelGraphAttestation.MappingMode = .semanticNameAndBlobReferenceV1,
        packedBlobReferenceCount: Int = 1,
        shippingGraphPath: String = "Encoder.mlmodelc/program.mil",
        shippingGraphByteCount: Int64? = nil,
        shippingGraphSHA256: String? = nil,
        packedGraphPath: String = "Encoder.mlmodelc/program.mil",
        packedGraphByteCount: Int64? = nil,
        packedGraphSHA256: String? = nil,
        packedWeightFileName: String = "weight.bin"
    ) -> DerivedModelGraphAttestation {
        let shippingReference = DerivedModelGraphAttestation.BlobReference(
            functionName: "main",
            blockName: "CoreML7",
            operationType: "constexpr_lut_to_dense",
            operationName: "shipping_encoder_layer_weight",
            outputName: "shipping_encoder_layer_weight_out",
            attributeName: "data",
            fileName: "@model_path/weights/weight.bin",
            offset: 64
        )
        let standaloneReference = DerivedModelGraphAttestation.BlobReference(
            functionName: "main",
            blockName: "CoreML7",
            operationType: "constexpr_lut_to_dense",
            operationName: "short_encoder_layer_weight",
            outputName: "short_encoder_layer_weight_out",
            attributeName: "data",
            fileName: "@model_path/weights/weight.bin",
            offset: 64
        )
        let packedReference = DerivedModelGraphAttestation.BlobReference(
            functionName: "main",
            blockName: "CoreML7",
            operationType: "constexpr_lut_to_dense",
            operationName: "packed_encoder_layer_weight",
            outputName: "packed_encoder_layer_weight_out",
            attributeName: "data",
            fileName: "@model_path/weights/\(packedWeightFileName)",
            offset: 64
        )
        let graphHash = sha256(Data("graph".utf8))
        return .init(
            mappingMode: mappingMode,
            modelBundlePath: "Encoder.mlmodelc",
            shippingGraph: .init(
                path: shippingGraphPath,
                byteCount: shippingGraphByteCount ?? Int64(program.count),
                sha256: shippingGraphSHA256 ?? sha256(program),
                operationCount: 3_398,
                blobReferenceCount: 1
            ),
            standaloneGraph: .init(
                path: "standalone/Encoder.mlmodel",
                byteCount: 90,
                sha256: graphHash,
                operationCount: 3_396,
                blobReferenceCount: 1
            ),
            packedGraph: .init(
                path: packedGraphPath,
                byteCount: packedGraphByteCount ?? Int64(program.count),
                sha256: packedGraphSHA256 ?? sha256(program),
                operationCount: 3_396,
                blobReferenceCount: packedBlobReferenceCount
            ),
            tensors: [
                .init(
                    semanticTensorName: "encoder.layers.0.self_attention.linear_q.weight",
                    role: .sharedFromSource,
                    dataType: "uint8-palettized",
                    shape: [tensorByteCount],
                    decodedByteCount: tensorByteCount,
                    decodedSHA256: tensorSHA256,
                    standaloneReference: standaloneReference,
                    packedReference: packedReference,
                    shippingReference: shippingReference
                )
            ]
        )
    }

    fileprivate func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate func exactRelativeFiles(in directory: URL) throws -> [String] {
        let manager = FileManager.default
        let prefix = directory.standardizedFileURL.path + "/"
        let enumerator = try XCTUnwrap(
            manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        return try enumerator.compactMap { item -> String? in
            let url = try XCTUnwrap(item as? URL)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            return String(url.standardizedFileURL.path.dropFirst(prefix.count))
        }.sorted()
    }

    fileprivate func canonicalTemporaryPath(_ url: URL?) -> String? {
        url?.path.replacingOccurrences(of: "/private/var/", with: "/var/")
    }
}
