import DictationCore
import Foundation

/// Model installation status.
public enum ModelState: Sendable, Equatable {
    case notInstalled
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case verifying(checked: Int, total: Int)
    case ready(directory: URL)
    case repairRequired(String)
    case failed(ModelStoreError)
    case deleting

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var requiresRepair: Bool {
        if case .repairRequired = self { return true }
        return false
    }

    /// Percentage of completion for the indicator, if it is meaningful.
    public var progress: Double? {
        switch self {
        case let .downloading(received, total) where total > 0:
            return min(1, Double(received) / Double(total))
        case let .verifying(checked, total) where total > 0:
            return Double(checked) / Double(total)
        default:
            return nil
        }
    }
}

public enum ModelStoreError: Error, Sendable, Equatable {
    case manifest(String)
    case download(String)
    case verification(String)
    case install(String)
    case repairRequired(String)
    /// The folder from which the user asked to take the model is not suitable.
    case importSource(String)
    case notEnoughDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case cancelled
}

/// Test seam to simulate process kill between file steps promotion.
public enum ModelPromotionCheckpoint: Sendable, Equatable, CaseIterable {
    case afterBackup
    case afterStagingMove
    case afterReadyMarker
    case afterBackupRemoval
}

/// Installing, checking and deleting the model.
///
/// Actor, because setting, deleting and reading state should not
/// intersect. The order is strict: download to staging → check there →
/// move in one motion → record the ready mark. Intermediate
/// the state never looks like a working setup.
public actor ModelStore {
    private let manifest: ModelManifest
    private let layout: ModelInstallLayout
    private let downloader: ModelDownloading
    private let verifier: ModelVerifier
    private let fileManager: FileManager
    private let injectedPromotionFailure: ModelPromotionCheckpoint?

    private var state: ModelState = .notInstalled
    private var observers: [UUID: AsyncStream<ModelState>.Continuation] = [:]
    private var activeTask: Task<Void, Never>?

    public init(
        manifest: ModelManifest,
        layout: ModelInstallLayout,
        downloader: ModelDownloading = URLSessionModelDownloader(),
        verifier: ModelVerifier = ModelVerifier(),
        fileManager: FileManager = .default,
        injectedPromotionFailure: ModelPromotionCheckpoint? = nil
    ) {
        self.manifest = manifest
        self.layout = layout
        self.downloader = downloader
        self.verifier = verifier
        self.fileManager = fileManager
        self.injectedPromotionFailure = injectedPromotionFailure
    }

    // MARK: - Observation

    public func currentState() -> ModelState { state }

    /// State flow for the interface. The current value comes first.
    public func states() -> AsyncStream<ModelState> {
        AsyncStream { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func setState(_ newState: ModelState) {
        state = newState
        for continuation in observers.values {
            continuation.yield(newState)
        }
    }

    // MARK: - Checking what is already installed

    /// Inspect the disk and update the state.
    ///
    /// The installation is considered ready only if the label matches the
    /// current manifest. Everything else is “not installed”, even if the files
    /// partially in place.
    @discardableResult
    public func refreshState() -> ModelState {
        do {
            try recoverInterruptedPromotion()
        } catch {
            setState(.repairRequired("couldn't recover an interrupted model update"))
            return state
        }
        sweepStaleStaging()

        guard fileManager.fileExists(atPath: layout.readyMarker.path) else {
            if fileManager.fileExists(atPath: layout.installedDirectory.path) {
                setState(.repairRequired("the model's ready marker is missing"))
                return state
            }
            setState(.notInstalled)
            return state
        }

        let marker: ModelReadyMarker
        do {
            let data = try LocalFile.read(layout.readyMarker)
            marker = try JSONDecoder().decode(ModelReadyMarker.self, from: data)
            guard marker.describesSameFiles(manifest) else {
                throw ModelStoreError.repairRequired("the model marker is incompatible with this app version")
            }
        } catch let error as ModelStoreError {
            setRefreshFailure(error)
            return state
        } catch {
            setState(.repairRequired("the model marker is damaged"))
            return state
        }

        // The revision is the same, but the version of FluidAudio in the label is different - this is an update
        // applications on top of entire files, not corruption. Let's check everything again
        // checksums and rewrite the label. There is not a byte of network here:
        // exactly for this reason the check is separated from “other files”.
        let verifiedMarker = marker.matches(manifest)
            ? marker
            : ModelReadyMarker(
                revision: marker.revision,
                fluidAudioVersion: marker.fluidAudioVersion,
                fileCount: marker.fileCount,
                totalByteCount: marker.totalByteCount,
                verifiedAt: marker.verifiedAt,
                installedFiles: nil
            )

        do {
            let metadata = try validateInstalledFiles(marker: verifiedMarker)
            if marker.installedFiles != metadata || !marker.matches(manifest) {
                try writeReadyMarker(installedFiles: metadata)
            }
        } catch let error as ModelStoreError {
            setRefreshFailure(error)
            return state
        } catch {
            setState(.repairRequired(error.localizedDescription))
            return state
        }

        setState(.ready(directory: layout.installedDirectory))
        return state
    }

    private func setRefreshFailure(_ error: ModelStoreError) {
        if case let .repairRequired(detail) = error {
            setState(.repairRequired(detail))
        } else {
            setState(.failed(error))
        }
    }

    /// Check the exact inventory and dimensions. If the metadata has changed either this
    /// marker of the old format, SHA-256 is confirmed before Ready.
    private func validateInstalledFiles(
        marker: ModelReadyMarker
    ) throws -> [ModelReadyMarker.InstalledFile] {
        let expectedPaths = Set(manifest.files.map(\.path))
        let engine = layout.engineDirectory
        guard fileManager.fileExists(atPath: engine.path) else {
            throw ModelStoreError.repairRequired("the model folder is missing")
        }

        guard let enumerator = fileManager.enumerator(
            at: engine,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else {
            throw ModelStoreError.repairRequired("couldn't read the model files")
        }

        var actualPaths = Set<String>()
        var metadata: [ModelReadyMarker.InstalledFile] = []
        let previous = Dictionary(uniqueKeysWithValues: (marker.installedFiles ?? []).map { ($0.path, $0) })

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ])
            guard values.isSymbolicLink != true else {
                throw ModelStoreError.repairRequired("\(url.lastPathComponent) is a symbolic link")
            }
            guard values.isRegularFile == true else { continue }

            // Finder creates `.DS_Store` when simply browsing a folder. This is his
            // garbage, not a model file: remove and continue because repair
            // here would mean transferring hundreds of megabytes due to an open window.
            if url.lastPathComponent == ".DS_Store" {
                try fileManager.removeItem(at: url)
                continue
            }

            let prefix = engine.standardizedFileURL.path + "/"
            guard url.standardizedFileURL.path.hasPrefix(prefix) else {
                throw ModelStoreError.repairRequired("a model file escaped the install directory")
            }
            let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            actualPaths.insert(path)

            guard let expected = manifest.files.first(where: { $0.path == path }) else {
                throw ModelStoreError.repairRequired("unexpected file \(path)")
            }
            let byteCount = Int64(values.fileSize ?? -1)
            guard byteCount == expected.byteCount else {
                throw ModelStoreError.repairRequired("wrong size for \(path)")
            }

            let item = ModelReadyMarker.InstalledFile(
                path: path,
                byteCount: byteCount,
                modifiedAt: values.contentModificationDate
            )
            if previous[path] != item {
                do {
                    try verifier.verify(file: expected, at: url)
                } catch {
                    throw ModelStoreError.repairRequired("\(path) is damaged")
                }
            }
            metadata.append(item)
        }

        guard actualPaths == expectedPaths else {
            let missing = expectedPaths.subtracting(actualPaths).sorted().joined(separator: ", ")
            throw ModelStoreError.repairRequired("missing files: \(missing)")
        }
        return metadata.sorted { $0.path < $1.path }
    }

    /// Remove abandoned staging directories from aborted attempts.
    ///
    /// While the installation is in progress, do not touch anything: disk inspection is called from
    /// interface and easily falls in the middle of the download - otherwise it would crash
    /// the folder into which the installation writes, and it would fall in the middle of the process.
    private func sweepStaleStaging() {
        guard activeTask == nil else { return }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: layout.modelDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Bring promotion to a consistent state, interrupted between rename.
    private func recoverInterruptedPromotion() throws {
        let destination = layout.installedDirectory
        let backup = layout.backupDirectory
        guard fileManager.fileExists(atPath: backup.path) else { return }

        let destinationHasMarker = fileManager.fileExists(
            atPath: destination.appending(path: ".ready.json").path
        )
        if destinationHasMarker {
            try fileManager.removeItem(at: backup)
        } else {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: backup, to: destination)
        }
    }

    // MARK: - Installation

    /// Download and install the model. Repeated calls during operation are ignored.
    public func install() async {
        guard activeTask == nil else { return }
        if case .ready = state { return }

        let task = Task { await performInstall() }
        activeTask = task
        await task.value
        activeTask = nil
    }

    /// Cancel installation. Anything downloaded to staging is deleted—we don’t keep untrusted remains.
    public func cancelInstall() {
        activeTask?.cancel()
    }

    /// Explicit recovery selected by the user. Unlike `install`,
    /// does not trust the previous `.ready`: Core ML warmup could detect a defect,
    /// which file inventory cannot diagnose. Old copy
    /// promotion still holds until a completely tested new one.
    public func repair() async {
        guard activeTask == nil else { return }
        let task = Task { await performInstall() }
        activeTask = task
        await task.value
        activeTask = nil
    }

    /// Take a model from a ready-made folder without going online.
    ///
    /// Second independent path to the model: a person downloaded it on another machine or
    /// received from a colleague. The check is exactly the same as after loading - everything
    /// SHA-256 sums from the manifest - so trust in the folder is not required.
    ///
    /// A folder is expected in which the paths from the manifest lie directly: `Encoder.mlmodelc/…`,
    /// `parakeet_vocab.json` and so on. This is the same folder that gives
    /// `ModelInstallLayout.engineDirectory` on the machine where the model is already installed.
    public func importModel(from directory: URL) async {
        guard activeTask == nil else { return }
        if case .ready = state { return }

        let task = Task { await performImport(from: directory) }
        activeTask = task
        await task.value
        activeTask = nil
    }

    private func performInstall() async {
        await runInstall { staging in
            try await self.downloadAll(into: staging)
        }
    }

    private func performImport(from source: URL) async {
        await runInstall { staging in
            try self.copyAll(from: source, into: staging)
        }
    }

    /// General skeleton of the installation: assemble into staging, check, move.
    ///
    /// Loading and importing differ only in where the files come from. Everything
    /// the rest - checking amounts, atomic moving, cleaning up after yourself for any
    /// error - must match, otherwise one of the paths will sooner or later
    /// weaker than the other.
    private func runInstall(collect: (URL) async throws -> Void) async {
        let attempt = UUID()
        let staging = layout.stagingDirectory(attempt: attempt)

        do {
            try preflightDiskSpace()
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            try await collect(staging)
            try Task.checkCancellation()
            try verifyAll(inside: staging)
            try Task.checkCancellation()
            try promote(from: staging)

            excludeFromBackup(layout.modelDirectory)
            setState(.ready(directory: layout.installedDirectory))
        } catch is CancellationError {
            do {
                try removeStaging(staging)
                setState(.notInstalled)
            } catch {
                setState(.failed(.install("download cancelled, but the partial files weren't deleted: \(error.localizedDescription)")))
            }
        } catch let error as ModelStoreError {
            let primary = String(describing: error)
            do {
                try removeStaging(staging)
                setState(.failed(error))
            } catch {
                setState(.failed(.install("\(primary); staging wasn't deleted: \(error.localizedDescription)")))
            }
        } catch {
            let primary = error.localizedDescription
            do {
                try removeStaging(staging)
                setState(.failed(.install(primary)))
            } catch {
                setState(.failed(.install("\(primary); staging wasn't deleted: \(error.localizedDescription)")))
            }
        }
    }

    private func removeStaging(_ staging: URL) throws {
        guard fileManager.fileExists(atPath: staging.path) else { return }
        try fileManager.removeItem(at: staging)
    }

    /// Copy manifest files from someone else's folder to staging.
    ///
    /// We copy, not transfer: the folder is someone else’s, you cannot take files from it.
    private func copyAll(from source: URL, into staging: URL) throws {
        let total = manifest.totalByteCount
        var completed: Int64 = 0
        setState(.downloading(receivedBytes: 0, totalBytes: total))

        for file in manifest.files {
            try Task.checkCancellation()

            // The path barrier is the same and just as strict: the file that arrived
            // outside, it has no more trust than what was downloaded. Are being checked
            // both sides: where we take it from and where we put it.
            let origin: URL
            let destination: URL
            do {
                origin = try layout.destination(for: file, inside: source)
                destination = try layout.destination(
                    for: file,
                    inside: layout.engineDirectory(inside: staging)
                )
            } catch {
                throw ModelStoreError.importSource("the path \(file.path) leads outside the folder")
            }
            try checkImportable(origin, path: file.path)

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try fileManager.copyItem(at: origin, to: destination)
            } catch {
                throw ModelStoreError.importSource("couldn't copy \(file.path): \(error.localizedDescription)")
            }

            completed += file.byteCount
            setState(.downloading(receivedBytes: completed, totalBytes: total))
        }
    }

    /// Is the file from someone else’s folder suitable for copying?
    ///
    /// A symbolic link is rejected separately: its content can be replaced
    /// after checking the amount, and a pointer would remain in the installed model
    /// out instead of the file.
    private func checkImportable(_ url: URL, path: String) throws {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard let values else {
            throw ModelStoreError.importSource("the folder has no file \(path)")
        }
        if values.isSymbolicLink == true {
            throw ModelStoreError.importSource("\(path) is a symbolic link, but a regular file is required")
        }
        guard values.isRegularFile == true else {
            throw ModelStoreError.importSource("\(path) is not a regular file")
        }
    }

    /// Make sure there is enough space: files are first stored in staging, then moved,
    /// therefore, the peak reserve is needed a little more than the model itself.
    private func preflightDiskSpace() throws {
        let required = Int64(Double(manifest.totalByteCount) * 1.2)
        let values = try? layout.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }

        guard available > required else {
            throw ModelStoreError.notEnoughDiskSpace(
                requiredBytes: required,
                availableBytes: Int64(available)
            )
        }
    }

    private func downloadAll(into staging: URL) async throws {
        let total = manifest.totalByteCount
        var completed: Int64 = 0
        setState(.downloading(receivedBytes: 0, totalBytes: total))

        for file in manifest.files {
            try Task.checkCancellation()

            let sources = manifest.downloadURLs(for: file)
            guard !sources.isEmpty else {
                throw ModelStoreError.manifest("couldn't build a URL for \(file.path)")
            }
            let destination = try layout.destination(for: file, inside: layout.engineDirectory(inside: staging))
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let alreadyDone = completed
            let temporary = try await downloadFromAnySource(
                sources,
                file: file,
                alreadyDone: alreadyDone,
                total: total
            )

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            completed += file.byteCount
            setState(.downloading(receivedBytes: completed, totalBytes: total))
        }
    }

    /// Go through the addresses from top to bottom until the file is downloaded.
    ///
    /// Source failure and user failure are two different things. No file, no
    /// access, no host - a reason to take the next address. Cancellation is a reason
    /// stop completely: going through the mirrors after pressing “cancel” means
    /// continue to download 483 MB despite a direct command.
    private func downloadFromAnySource(
        _ sources: [URL],
        file: ModelManifest.File,
        alreadyDone: Int64,
        total: Int64
    ) async throws -> URL {
        var failures: [String] = []

        for (index, url) in sources.enumerated() {
            do {
                return try await downloader.download(
                    from: url,
                    expectedBytes: file.byteCount,
                    onProgress: { [weak self] received in
                        Task { [weak self] in
                            await self?.reportDownloadProgress(alreadyDone + received, total: total)
                        }
                    }
                )
            } catch ModelDownloadError.cancelled {
                throw CancellationError()
            } catch let error as ModelDownloadError {
                failures.append("\(url.host() ?? url.absoluteString): \(error)")
                // Progress could go forward on an unsuccessful attempt - return
                // it back, otherwise the indicator will move and overtake itself.
                reportDownloadProgress(alreadyDone, total: total)
                if index == sources.count - 1 {
                    throw ModelStoreError.download("\(file.path): \(failures.joined(separator: "; "))")
                }
            }
        }

        throw ModelStoreError.download("\(file.path): no sources left")
    }

    private func reportDownloadProgress(_ received: Int64, total: Int64) {
        guard case .downloading = state else { return }
        setState(.downloading(receivedBytes: received, totalBytes: total))
    }

    private func verifyAll(inside staging: URL) throws {
        setState(.verifying(checked: 0, total: manifest.files.count))
        do {
            for (index, file) in manifest.files.enumerated() {
                try Task.checkCancellation()
                let destination = try layout.destination(for: file, inside: layout.engineDirectory(inside: staging))
                try verifier.verify(file: file, at: destination)
                setState(.verifying(checked: index + 1, total: manifest.files.count))
            }
        } catch let failure as ModelVerifier.Failure {
            throw ModelStoreError.verification(String(describing: failure))
        }
    }

    /// Crash-safe swap: the old model remains in backup until the marker of the new one.
    private func promote(from staging: URL) throws {
        let destination = layout.installedDirectory
        let backup = layout.backupDirectory
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
            }
            try injectPromotionFailure(at: .afterBackup)
            try fileManager.moveItem(at: staging, to: destination)
            try injectPromotionFailure(at: .afterStagingMove)
            let metadata = try installedMetadataWithoutMarker()
            try writeReadyMarker(installedFiles: metadata)
            try injectPromotionFailure(at: .afterReadyMarker)
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            try injectPromotionFailure(at: .afterBackupRemoval)
        } catch {
            throw ModelStoreError.install(error.localizedDescription)
        }
    }

    private func injectPromotionFailure(at checkpoint: ModelPromotionCheckpoint) throws {
        guard injectedPromotionFailure == checkpoint else { return }
        throw ModelStoreError.install("injected promotion failure: \(checkpoint)")
    }

    private func installedMetadataWithoutMarker() throws -> [ModelReadyMarker.InstalledFile] {
        try manifest.files.map { file in
            let url = try layout.destination(for: file, inside: layout.engineDirectory)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return .init(
                path: file.path,
                byteCount: Int64(values.fileSize ?? -1),
                modifiedAt: values.contentModificationDate
            )
        }.sorted { $0.path < $1.path }
    }

    private func writeReadyMarker(installedFiles: [ModelReadyMarker.InstalledFile]) throws {
        let marker = ModelReadyMarker(
            manifest: manifest,
            verifiedAt: Date(),
            installedFiles: installedFiles
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: layout.readyMarker, options: .atomic)
    }

    /// The model is a downloadable cache; it has no place in backups.
    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    // MARK: - Delete

    /// Delete the installed model.
    ///
    /// If there is a download going on at this moment, first stop it and wait
    /// end. Otherwise, deletion would remove the folder from under the live installation: that
    /// would continue to write to nowhere and would end up with a vague error instead
    /// clear “model deleted”.
    public func delete() async {
        if let activeTask {
            activeTask.cancel()
            await activeTask.value
        }

        setState(.deleting)
        do {
            if fileManager.fileExists(atPath: layout.modelDirectory.path) {
                try fileManager.removeItem(at: layout.modelDirectory)
            }
            setState(.notInstalled)
        } catch {
            setState(.failed(.install("couldn't delete the model: \(error.localizedDescription)")))
        }
    }
}
