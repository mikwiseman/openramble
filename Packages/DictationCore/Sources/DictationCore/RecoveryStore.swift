import Foundation

public enum RecordingRecoveryOutcome: Sendable, Equatable {
    case committed(URL)
    case notCommitted(sourceRemains: Bool, reason: String)
    case busy(sourceRemains: Bool)
    case deleted
}

public enum RecordingRecoveryStorageError: Error, Sendable, Equatable {
    case automaticRecoveryDisabled
}

private final class RecordingRecoveryTicketState: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: RecordingRecoveryOutcome?
    private var waiters: [CheckedContinuation<RecordingRecoveryOutcome, Never>] = []
    private var deleteRequested = false
    private var ownedPaths: [URL]
    private var ownedPathSet: Set<URL>
    private let pendingMarker: URL?
    private var publishedURL: URL?
    private var publicationHandlers: [@Sendable (URL) -> Void] = []

    init(ownedPaths: [URL], pendingMarker: URL?) {
        self.ownedPaths = ownedPaths
        ownedPathSet = Set(ownedPaths)
        self.pendingMarker = pendingMarker
    }

    func value() async -> RecordingRecoveryOutcome {
        await withCheckedContinuation { continuation in
            let immediate: RecordingRecoveryOutcome? = lock.withLock {
                if let outcome { return outcome }
                waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func addOwnedPath(_ url: URL) {
        let shouldDelete = lock.withLock {
            if ownedPathSet.insert(url).inserted { ownedPaths.append(url) }
            return deleteRequested
        }
        if shouldDelete { RecordingFileDisposer.shared.submit(url) }
    }

    func isDeleteRequested() -> Bool { lock.withLock { deleteRequested } }

    func ownedPathsSnapshot() -> [URL] { lock.withLock { ownedPaths } }

    func requestDelete() {
        let paths: [URL] = lock.withLock {
            deleteRequested = true
            if outcome != nil { outcome = .deleted }
            return ownedPaths
        }
        RecordingFileDisposer.shared.submit(paths)
    }

    func complete(_ proposed: RecordingRecoveryOutcome) {
        let completion: (RecordingRecoveryOutcome, [CheckedContinuation<RecordingRecoveryOutcome, Never>], [URL])? = lock.withLock {
            guard outcome == nil else { return nil }
            let resolved: RecordingRecoveryOutcome = deleteRequested ? .deleted : proposed
            outcome = resolved
            let pending = waiters
            waiters.removeAll()
            return (resolved, pending, deleteRequested ? ownedPaths : [])
        }
        guard let completion else { return }
        RecordingFileDisposer.shared.submit(completion.2)
        for waiter in completion.1 { waiter.resume(returning: completion.0) }
    }

    func onPublished(_ handler: @escaping @Sendable (URL) -> Void) {
        let published: URL? = lock.withLock {
            if let publishedURL { return publishedURL }
            publicationHandlers.append(handler)
            return nil
        }
        if let published { handler(published) }
    }

    func markPublished() {
        let publication: (URL, URL?, [@Sendable (URL) -> Void])? = lock.withLock {
            guard !deleteRequested,
                  case let .committed(destination) = outcome,
                  publishedURL == nil
            else { return nil }
            publishedURL = destination
            let handlers = publicationHandlers
            publicationHandlers.removeAll()
            return (destination, pendingMarker, handlers)
        }
        guard let publication else { return }
        if let marker = publication.1 { RecordingFileDisposer.shared.submit(marker) }
        for handler in publication.2 { handler(publication.0) }
    }
}

/// A recovery transaction survives the UI deadline that observed it.
///
/// Cancellation changes its disposition instead of merely cancelling a wait;
/// if a filesystem call returns late, every predeclared path is deleted before
/// the transaction resolves. `markPublished()` removes the crash marker only
/// after the controller has committed a visible Retry outcome.
public final class RecordingRecoveryTicket: @unchecked Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let destinationURL: URL
    private let state: RecordingRecoveryTicketState

    fileprivate init(
        id: UUID,
        sourceURL: URL,
        destinationURL: URL,
        pendingMarker: URL?
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        // Audio is deleted before its marker. If a kernel unlink wedges, the
        // surviving marker never falsely claims cleanup completed.
        var ownedPaths = sourceURL == destinationURL
            ? [sourceURL]
            : [sourceURL, destinationURL]
        if let pendingMarker { ownedPaths.append(pendingMarker) }
        state = RecordingRecoveryTicketState(
            ownedPaths: ownedPaths,
            pendingMarker: pendingMarker
        )
    }

    public func value() async -> RecordingRecoveryOutcome { await state.value() }
    public func requestDelete() { state.requestDelete() }
    /// Wait until the transaction has published every path it can create, then
    /// require an fsync-backed exact delete intent for the complete set.
    /// Callers may bound this wait, but a timeout must not be described as a
    /// durable cancellation.
    public func requestDeleteDurably() async -> Bool {
        state.requestDelete()
        _ = await state.value()
        return await RecordingFileDisposer.shared
            .submitAcknowledged(state.ownedPathsSnapshot())
            .value()
    }
    public func markPublished() { state.markPublished() }

    fileprivate func complete(_ outcome: RecordingRecoveryOutcome) { state.complete(outcome) }
    fileprivate func addOwnedPath(_ url: URL) { state.addOwnedPath(url) }
    fileprivate func onPublished(_ handler: @escaping @Sendable (URL) -> Void) {
        state.onPublished(handler)
    }
    fileprivate var deleteRequested: Bool { state.isDeleteRequested() }
}

private final class RecordingRecoveryTransactionGate: @unchecked Sendable {
    static let shared = RecordingRecoveryTransactionGate()
    private let lock = NSLock()
    private var occupied = false

    func tryAcquire() -> Bool {
        lock.withLock {
            guard !occupied else { return false }
            occupied = true
            return true
        }
    }

    func release() { lock.withLock { occupied = false } }
}

private final class RecordingRecoveryTransactionCoordinator: @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager
    private let gate: RecordingRecoveryTransactionGate
    private let maximumCount: Int
    private let maximumAge: TimeInterval
    private let maximumBytes: Int64
    private let maintenanceLock = NSLock()
    private var maintenanceInFlight = false
    private var maintenancePending = false

    init(
        directory: URL,
        fileManager: FileManager,
        maximumCount: Int,
        maximumAge: TimeInterval,
        maximumBytes: Int64,
        gate: RecordingRecoveryTransactionGate = .shared
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.maximumCount = maximumCount
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        self.gate = gate
    }

    func begin(_ source: URL) -> RecordingRecoveryTicket {
        let id = UUID()
        let shortID = id.uuidString.lowercased()
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = source.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL
            ? source
            : directory.appending(path: "recording-\(timestamp)-\(shortID).wav")
        let marker = directory.appending(path: ".openramble-recovery-\(shortID).pending")
        let ticket = RecordingRecoveryTicket(
            id: id,
            sourceURL: source,
            destinationURL: destination,
            pendingMarker: marker
        )

        guard gate.tryAcquire() else {
            ticket.complete(.busy(sourceRemains: true))
            return ticket
        }

        Task.detached(priority: .utility) { [self] in
            let committed = perform(ticket: ticket, marker: marker)
            gate.release()
            if committed { schedulePrune() }
        }
        return ticket
    }

    @discardableResult
    private func perform(ticket: RecordingRecoveryTicket, marker: URL) -> Bool {
        if ticket.deleteRequested {
            ticket.complete(.deleted)
            return false
        }
        let sourceDirectory = ticket.sourceURL.deletingLastPathComponent()
        if RecordingFileDisposer.shared.isStorageFaulted(in: sourceDirectory)
            || RecordingFileDisposer.shared.isStorageFaulted(in: directory)
            || RecordingDeletionIntent.hasStorageFault(
                in: sourceDirectory,
                fileManager: fileManager
            )
            || RecordingDeletionIntent.hasStorageFault(
                in: directory,
                fileManager: fileManager
            ) {
            ticket.complete(
                .notCommitted(
                    sourceRemains: fileManager.fileExists(atPath: ticket.sourceURL.path),
                    reason: "automatic recording recovery is disabled after a storage fault"
                )
            )
            return false
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // The marker is a keep/reconciliation lease, never a delete
            // tombstone. Failure to write it cannot make an already-readable
            // take less recoverable, so it must not abort the atomic move.
            try? Data(ticket.sourceURL.lastPathComponent.utf8).write(to: marker, options: .atomic)
            if ticket.deleteRequested {
                ticket.complete(.deleted)
                return false
            }
            if ticket.sourceURL.standardizedFileURL != ticket.destinationURL.standardizedFileURL {
                try fileManager.moveItem(at: ticket.sourceURL, to: ticket.destinationURL)
            }
            if ticket.deleteRequested {
                ticket.complete(.deleted)
                return false
            }
            guard fileManager.fileExists(atPath: ticket.destinationURL.path) else {
                ticket.complete(
                    .notCommitted(
                        sourceRemains: fileManager.fileExists(atPath: ticket.sourceURL.path),
                        reason: "recovery destination is unavailable"
                    )
                )
                return false
            }
            ticket.complete(.committed(ticket.destinationURL))
            return true
        } catch {
            // Some filesystem APIs can report an error after a rename became
            // externally visible. Reconcile the actual commit point instead
            // of reporting failure and later deleting a valid destination.
            let destinationExists = fileManager.fileExists(atPath: ticket.destinationURL.path)
            let sourceExists = fileManager.fileExists(atPath: ticket.sourceURL.path)
            if destinationExists, ticket.sourceURL == ticket.destinationURL || !sourceExists {
                ticket.complete(.committed(ticket.destinationURL))
                return true
            } else {
                ticket.complete(
                    .notCommitted(
                        sourceRemains: sourceExists,
                        reason: error.localizedDescription
                    )
                )
                return false
            }
        }
    }

    /// Coalesced one-flight maintenance. Even a permanently wedged directory
    /// scan retains one task and one pending bit; it cannot delay a committed
    /// ticket or accumulate one task per failed dictation.
    private func schedulePrune() {
        let launch = maintenanceLock.withLock {
            if maintenanceInFlight {
                maintenancePending = true
                return false
            }
            maintenanceInFlight = true
            return true
        }
        guard launch else { return }
        Task.detached(priority: .background) { [self] in drainPrune() }
    }

    private func drainPrune() {
        while true {
            bestEffortPrune()
            let again = maintenanceLock.withLock {
                if maintenancePending {
                    maintenancePending = false
                    return true
                }
                maintenanceInFlight = false
                return false
            }
            if !again { return }
        }
    }

    /// Retention is post-commit maintenance. A prune failure must never turn a
    /// successfully moved recording into a false failure; launch repeats it.
    private func bestEffortPrune(now: Date = Date()) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        var entries: [(url: URL, date: Date, bytes: Int64)] = []
        for url in urls where url.pathExtension.lowercased() == "wav" {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ), let date = values.contentModificationDate, let size = values.fileSize else { continue }
            if now.timeIntervalSince(date) > maximumAge {
                try? fileManager.removeItem(at: url)
            } else {
                entries.append((url, date, Int64(size)))
            }
        }
        entries.sort { $0.date < $1.date }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        while entries.count > maximumCount || total > maximumBytes {
            let oldest = entries.removeFirst()
            try? fileManager.removeItem(at: oldest.url)
            total -= oldest.bytes
        }
    }
}

// `RecoveryStore` used to live here, writing unrecognized text to disk.
// Now such text is kept only in process memory (Copy/Retry in the menu),
// and only WAVs end up on the disk after a technical error - see below.
// The `Recovered/` directory of old assemblies is removed by the application at startup.

/// WAV remaining after a technical error and available for re-ASR.
public protocol RecordingRecoveryStoring: Sendable {
    func preserve(_ source: URL) async throws -> URL?
    func beginPreserve(_ source: URL) -> RecordingRecoveryTicket
}

extension RecordingRecoveryStoring {
    public func beginPreserve(_ source: URL) -> RecordingRecoveryTicket {
        let ticket = RecordingRecoveryTicket(
            id: UUID(),
            sourceURL: source,
            destinationURL: source,
            pendingMarker: nil
        )
        Task {
            do {
                if let destination = try await preserve(source) {
                    ticket.addOwnedPath(destination)
                    ticket.complete(.committed(destination))
                } else {
                    ticket.complete(.notCommitted(sourceRemains: false, reason: "not preserved"))
                }
            } catch {
                ticket.complete(
                    .notCommitted(sourceRemains: true, reason: error.localizedDescription)
                )
            }
        }
        return ticket
    }
}

public struct AbandonedRecordingImportResult: Sendable, Equatable {
    public let recordings: [URL]
    /// How many recordings this very import rescued.
    ///
    /// Tells "something happened right now" apart from "left over from last
    /// week": an old leftover is not an event of this launch, and announcing
    /// it again would be a made-up error.
    public let newlyImportedCount: Int
    public let discardedCorruptCount: Int
    /// Exact delete identities were lost after a storage worker saturated.
    /// Ambiguous audio remains untouched and automatic recovery stays disabled
    /// until the support folder is inspected; no directory-wide deletion is
    /// ever inferred from this flag.
    public let storageFaulted: Bool

    public init(
        recordings: [URL],
        newlyImportedCount: Int,
        discardedCorruptCount: Int,
        storageFaulted: Bool = false
    ) {
        self.recordings = recordings
        self.newlyImportedCount = newlyImportedCount
        self.discardedCorruptCount = discardedCorruptCount
        self.storageFaulted = storageFaulted
    }
}

/// Production recovery for erroneous and interrupted recordings.
public actor RecordingRecoveryStore: RecordingRecoveryStoring {
    private let directory: URL
    private let maximumCount: Int
    private let maximumAge: TimeInterval
    private let maximumBytes: Int64
    private let fileManager: FileManager
    private let wavSynchronizer: (FileHandle) throws -> Void
    private let partialMover: (URL, URL) throws -> Void
    private let compatibilityGrace: TimeInterval
    private let maintenanceRetryDelay: TimeInterval
    private let idleScanInterval: TimeInterval
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceGeneration: UInt64 = 0
    private var maintainedTakesDirectory: URL?
    private var maintenanceObservers: [
        UUID: AsyncStream<AbandonedRecordingImportResult>.Continuation
    ] = [:]
    private nonisolated let transactionCoordinator: RecordingRecoveryTransactionCoordinator

    public init(
        directory: URL,
        maximumCount: Int = 10,
        maximumAge: TimeInterval = 7 * 24 * 3600,
        maximumBytes: Int64 = 1_073_741_824,
        fileManager: FileManager = .default,
        compatibilityGrace: TimeInterval = 60,
        maintenanceRetryDelay: TimeInterval = 5,
        idleScanInterval: TimeInterval = 60
    ) {
        precondition(compatibilityGrace >= 0 && compatibilityGrace.isFinite)
        precondition(maintenanceRetryDelay > 0 && maintenanceRetryDelay.isFinite)
        precondition(idleScanInterval > 0 && idleScanInterval.isFinite)
        self.directory = directory
        self.maximumCount = maximumCount
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
        self.compatibilityGrace = compatibilityGrace
        self.maintenanceRetryDelay = maintenanceRetryDelay
        self.idleScanInterval = idleScanInterval
        wavSynchronizer = { try $0.synchronize() }
        partialMover = { source, destination in
            try fileManager.moveItem(at: source, to: destination)
        }
        transactionCoordinator = RecordingRecoveryTransactionCoordinator(
            directory: directory,
            fileManager: fileManager,
            maximumCount: maximumCount,
            maximumAge: maximumAge,
            maximumBytes: maximumBytes
        )
    }

    /// Fault-injection initializer for crash-phase storage tests.
    init(
        directory: URL,
        maximumCount: Int = 10,
        maximumAge: TimeInterval = 7 * 24 * 3600,
        maximumBytes: Int64 = 1_073_741_824,
        fileManager: FileManager = .default,
        wavSynchronizer: @escaping (FileHandle) throws -> Void,
        partialMover: @escaping (URL, URL) throws -> Void,
        compatibilityGrace: TimeInterval = 60,
        maintenanceRetryDelay: TimeInterval = 5,
        idleScanInterval: TimeInterval = 60
    ) {
        precondition(compatibilityGrace >= 0 && compatibilityGrace.isFinite)
        precondition(maintenanceRetryDelay > 0 && maintenanceRetryDelay.isFinite)
        precondition(idleScanInterval > 0 && idleScanInterval.isFinite)
        self.directory = directory
        self.maximumCount = maximumCount
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
        self.wavSynchronizer = wavSynchronizer
        self.partialMover = partialMover
        self.compatibilityGrace = compatibilityGrace
        self.maintenanceRetryDelay = maintenanceRetryDelay
        self.idleScanInterval = idleScanInterval
        transactionCoordinator = RecordingRecoveryTransactionCoordinator(
            directory: directory,
            fileManager: fileManager,
            maximumCount: maximumCount,
            maximumAge: maximumAge,
            maximumBytes: maximumBytes
        )
    }

    deinit {
        maintenanceTask?.cancel()
        for observer in maintenanceObservers.values { observer.finish() }
    }

    /// Results produced after the startup call, including fresh crash files
    /// that cross the compatibility grace while this process remains alive.
    /// The app can update its recovery count and surface storage faults without
    /// polling or relaunching.
    public func maintenanceResults() -> AsyncStream<AbandonedRecordingImportResult> {
        let id = UUID()
        return AsyncStream { continuation in
            maintenanceObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeMaintenanceObserver(id) }
            }
        }
    }

    private func removeMaintenanceObserver(_ id: UUID) {
        maintenanceObservers.removeValue(forKey: id)
    }

    public nonisolated func beginPreserve(_ source: URL) -> RecordingRecoveryTicket {
        let ticket = transactionCoordinator.begin(source)
        ticket.onPublished { [weak self] _ in
            Task {
                await self?.recordingWasPublished(
                    sourceDirectory: source.deletingLastPathComponent()
                )
            }
        }
        return ticket
    }

    private func recordingWasPublished(sourceDirectory: URL) {
        do {
            let result = AbandonedRecordingImportResult(
                recordings: try recordings(),
                newlyImportedCount: 0,
                discardedCorruptCount: 0,
                storageFaulted: automaticRecoveryIsFaulted(
                    sourceDirectory: maintainedTakesDirectory ?? sourceDirectory
                )
            )
            for observer in maintenanceObservers.values { observer.yield(result) }
            if let maintainedTakesDirectory {
                scheduleMaintenance(from: maintainedTakesDirectory)
            }
        } catch {
            if let maintainedTakesDirectory {
                scheduleMaintenance(
                    from: maintainedTakesDirectory,
                    after: maintenanceRetryDelay
                )
            }
        }
    }

    public func preserve(_ source: URL) throws -> URL? {
        guard !automaticRecoveryIsFaulted(sourceDirectory: source.deletingLastPathComponent()) else {
            throw RecordingRecoveryStorageError.automaticRecoveryDisabled
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination: URL
        if source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            destination = source
        } else {
            destination = directory.appending(
                path: "recording-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(8)).wav"
            )
            try fileManager.moveItem(at: source, to: destination)
        }
        // The move is the commit point. Retention maintenance is retried at
        // launch and may not retroactively convert a valid destination into a
        // thrown preservation failure.
        try? prune()
        let committed = fileManager.fileExists(atPath: destination.path) ? destination : nil
        if let maintainedTakesDirectory {
            scheduleMaintenance(from: maintainedTakesDirectory)
        }
        return committed
    }

    /// Transfer WAV remaining in Takes after kill/crash/power loss, then keep a
    /// single bounded maintenance loop alive. The loop is what closes the old
    /// "fresh at launch, stranded until next launch" gap and enforces retention
    /// on a quiet long-running app.
    public func importAbandoned(from takesDirectory: URL) throws -> AbandonedRecordingImportResult {
        maintainedTakesDirectory = takesDirectory
        cancelScheduledMaintenance()
        do {
            let result = try importAbandonedOnce(from: takesDirectory)
            scheduleMaintenance(from: takesDirectory)
            return result
        } catch {
            scheduleMaintenance(from: takesDirectory, after: maintenanceRetryDelay)
            throw error
        }
    }

    private func importAbandonedOnce(
        from takesDirectory: URL
    ) throws -> AbandonedRecordingImportResult {
        // A delete sidecar is user intent, not a best-effort cleanup hint. It
        // wins over repair/import even when a previous unlink wedged. Reconcile
        // both locations because a cancellation may race the recovery move.
        let allowedParents = Set([
            directory.standardizedFileURL,
            takesDirectory.standardizedFileURL
        ])
        let tombstonedRecovery = try reconcileDeletionIntents(
            in: directory,
            allowedTargetParents: allowedParents
        )
        let tombstonedTakes = try reconcileDeletionIntents(
            in: takesDirectory,
            allowedTargetParents: allowedParents
        )
        let tombstoned = tombstonedRecovery.union(tombstonedTakes)
        if automaticRecoveryIsFaulted(sourceDirectory: takesDirectory) {
            return AbandonedRecordingImportResult(
                recordings: [],
                newlyImportedCount: 0,
                discardedCorruptCount: 0,
                storageFaulted: true
            )
        }
        try reconcilePendingTransactions(from: takesDirectory)
        let promotedMemoryRecoveries = try reconcileMemoryRecoveryPartials(
            from: takesDirectory,
            initiallyTombstoned: tombstoned
        )
        guard fileManager.fileExists(atPath: takesDirectory.path) else {
            if fileManager.fileExists(atPath: directory.path) {
                try prune()
            }
            return AbandonedRecordingImportResult(
                recordings: try recordings(),
                newlyImportedCount: 0,
                discardedCorruptCount: 0,
                storageFaulted: false
            )
        }
        let entries = try fileManager.contentsOfDirectory(
            at: takesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        var newlyImportedCount = 0
        var discardedCorruptCount = 0
        for entry in entries where entry.pathExtension.lowercased() == "wav" {
            // Recheck at the point of use. Another running instance may have
            // persisted Escape/success after the initial directory scan.
            if tombstoned.contains(entry.standardizedFileURL)
                || hasDeletionIntent(for: entry, allowedParents: allowedParents) {
                try? fileManager.removeItem(at: entry)
                continue
            }
            // A kernel lease is causal ownership. Unlike mtime it remains
            // correct when a live writer is wedged for minutes, and the OS
            // releases it automatically after crash/process death.
            guard let recoveryLease = RecordingFileLease.claimExclusiveIfAvailable(at: entry) else {
                continue
            }
            // This defer belongs to the loop-body scope, so every `continue`
            // and every thrown branch releases only this entry's claim. Until
            // then the lease stays held through repair, duration policy, and
            // move/delete.
            defer { recoveryLease.release() }
            // A take modified moments ago is not abandoned — it may be the
            // live recording of ANOTHER running instance (a debug build and
            // the release build share this folder). Touching it would steal
            // the file out from under the recorder mid-dictation. A genuine
            // crash leftover ages past this window and is picked up by the
            // bounded in-process maintenance pass.
            if let modified = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate,
               Date().timeIntervalSince(modified) < compatibilityGrace,
               !promotedMemoryRecoveries.contains(entry.standardizedFileURL) {
                continue
            }
            do {
                let payloadBytes = try repairAbandonedWAV(at: entry)
                // A fragment shorter than the recognition minimum is an
                // accidental key press that outlived a kill, not lost speech.
                // The main dictation path deletes such takes silently; the
                // import must behave the same — otherwise every launch shows
                // "a recording after a failure" whose retry can only ever
                // produce an empty result.
                guard DictationDurationPolicy.isWorthTranscribing(
                    duration: TimeInterval(payloadBytes) / TimeInterval(Self.bytesPerSecond)
                ) else {
                    try fileManager.removeItem(at: entry)
                    continue
                }
                if try preserve(entry) != nil { newlyImportedCount += 1 }
            } catch let error as CocoaError where error.code == .fileReadCorruptFile {
                // An exactly unusable fragment should not block the rest
                // records after crash. This is just the native WAVWriter file from
                //Takes; other people's files do not go here. The deletion will reach the UI
                // counter, so it is not hidden from humans.
                try fileManager.removeItem(at: entry)
                discardedCorruptCount += 1
            }
        }
        // Launch is the retention checkpoint. Preserving prunes too, but a
        // quiet machine may not preserve anything for weeks — without this
        // pass an old recording would outlive the promised retention window.
        if fileManager.fileExists(atPath: directory.path) {
            try prune()
        }
        return AbandonedRecordingImportResult(
            recordings: try recordings(),
            newlyImportedCount: newlyImportedCount,
            discardedCorruptCount: discardedCorruptCount,
            storageFaulted: false
        )
    }

    private func cancelScheduledMaintenance() {
        maintenanceGeneration &+= 1
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    private func scheduleMaintenance(
        from takesDirectory: URL,
        after forcedDelay: TimeInterval? = nil
    ) {
        guard !automaticRecoveryIsFaulted(sourceDirectory: takesDirectory) else {
            cancelScheduledMaintenance()
            return
        }
        let delay = max(
            0.001,
            forcedDelay ?? nextMaintenanceDelay(from: takesDirectory)
        )
        maintenanceGeneration &+= 1
        let generation = maintenanceGeneration
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledMaintenance(
                from: takesDirectory,
                generation: generation
            )
        }
    }

    private func runScheduledMaintenance(
        from takesDirectory: URL,
        generation: UInt64
    ) {
        guard generation == maintenanceGeneration,
              maintainedTakesDirectory?.standardizedFileURL
                == takesDirectory.standardizedFileURL
        else { return }
        maintenanceTask = nil
        do {
            let result = try importAbandonedOnce(from: takesDirectory)
            for observer in maintenanceObservers.values { observer.yield(result) }
            scheduleMaintenance(from: takesDirectory)
        } catch {
            scheduleMaintenance(from: takesDirectory, after: maintenanceRetryDelay)
        }
    }

    /// Use the nearest causal deadline, capped by a low-rate idle scan so a
    /// crash in another concurrently running build is also discovered without
    /// relaunch. A stale but leased writer is retried without ever touching it.
    private func nextMaintenanceDelay(from takesDirectory: URL, now: Date = Date()) -> TimeInterval {
        var next = idleScanInterval

        func considerGrace(_ url: URL) {
            guard let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else {
                next = min(next, maintenanceRetryDelay)
                return
            }
            let remaining = compatibilityGrace - now.timeIntervalSince(modified)
            next = min(next, remaining > 0 ? remaining : maintenanceRetryDelay)
        }

        if let entries = try? fileManager.contentsOfDirectory(
            at: takesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for entry in entries {
                let name = entry.lastPathComponent
                if entry.pathExtension.lowercased() == "wav"
                    || (name.hasPrefix("memory-recovery-")
                        && name.hasSuffix(".wav.partial")) {
                    considerGrace(entry)
                }
            }
        }

        if let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasPrefix(".openramble-recovery-")
                    && name.hasSuffix(".pending") {
                    considerGrace(entry)
                    continue
                }
                guard entry.pathExtension.lowercased() == "wav",
                      let modified = try? entry.resourceValues(
                        forKeys: [.contentModificationDateKey]
                      ).contentModificationDate
                else { continue }
                let remaining = maximumAge - now.timeIntervalSince(modified)
                next = min(next, remaining > 0 ? remaining : maintenanceRetryDelay)
            }
        }
        return next
    }

    /// Finish exact delete intents left by a killed process or a wedged unlink.
    ///
    /// An absent target is never enough to clear its intent: another instance
    /// can remain wedged in a non-cancellable create for an unbounded time.
    /// Reconciliation clears a marker only after observing that exact target
    /// present and then confirming it absent after unlink.
    @discardableResult
    private func reconcileDeletionIntents(
        in parent: URL,
        allowedTargetParents: Set<URL>
    ) throws -> Set<URL> {
        guard fileManager.fileExists(atPath: parent.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        var tombstoned: Set<URL> = []

        for marker in entries {
            if let targets = RecordingDeletionIntent.batchTargets(
                for: marker,
                allowedParents: allowedTargetParents,
                fileManager: fileManager
            ) {
                var everyTargetConfirmedRemoved = true
                for target in targets {
                    tombstoned.insert(target.standardizedFileURL)
                    let existedBefore = fileManager.fileExists(atPath: target.path)
                    try? fileManager.removeItem(at: target)
                    if !existedBefore || fileManager.fileExists(atPath: target.path) {
                        everyTargetConfirmedRemoved = false
                    }
                }
                if everyTargetConfirmedRemoved {
                    try? fileManager.removeItem(at: marker)
                }
                continue
            }

            guard let target = RecordingDeletionIntent.targetURL(
                for: marker,
                fileManager: fileManager
            ) else { continue }
            tombstoned.insert(target.standardizedFileURL)
            let existedBefore = fileManager.fileExists(atPath: target.path)
            try? fileManager.removeItem(at: target)
            if existedBefore, !fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: marker)
            }
        }
        return tombstoned
    }

    private func hasDeletionIntent(
        for target: URL,
        allowedParents: Set<URL>? = nil
    ) -> Bool {
        let normalizedAllowed = allowedParents ?? Set([
            target.deletingLastPathComponent().standardizedFileURL,
            directory.standardizedFileURL
        ])
        let exact = RecordingDeletionIntent.markerURL(for: target)
        if RecordingDeletionIntent.targetURL(for: exact, fileManager: fileManager)?
            .standardizedFileURL == target.standardizedFileURL {
            return true
        }
        if let entries = try? fileManager.contentsOfDirectory(
            at: target.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ), entries.contains(where: { marker in
            RecordingDeletionIntent.batchTargets(
                for: marker,
                allowedParents: normalizedAllowed,
                fileManager: fileManager
            )?.contains(target.standardizedFileURL) == true
        }) {
            return true
        }
        return false
    }

    /// A kill after sealing memory recovery but before its same-directory
    /// rename leaves `memory-recovery-*.wav.partial`. Fresh files can belong to
    /// another live instance. Stale files are accepted only if they match our
    /// exact writer format; valid speech is atomically promoted to `.wav`, and
    /// unusable prefixes are purged rather than leaked forever.
    private func reconcileMemoryRecoveryPartials(
        from takesDirectory: URL,
        initiallyTombstoned: Set<URL>,
        now: Date = Date()
    ) throws -> Set<URL> {
        guard fileManager.fileExists(atPath: takesDirectory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: takesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        var promoted: Set<URL> = []
        for partial in entries {
            let name = partial.lastPathComponent
            guard name.hasPrefix("memory-recovery-"),
                  name.hasSuffix(".wav.partial")
            else { continue }
            let final = partial.deletingPathExtension()

            if initiallyTombstoned.contains(partial.standardizedFileURL)
                || initiallyTombstoned.contains(final.standardizedFileURL)
                || hasDeletionIntent(for: partial)
                || hasDeletionIntent(for: final) {
                try? fileManager.removeItem(at: partial)
                try? fileManager.removeItem(at: final)
                continue
            }

            guard let recoveryLease = RecordingFileLease.claimExclusiveIfAvailable(at: partial) else {
                continue
            }
            // Keep ownership continuously through validation, repair, and the
            // atomic partial→final publish. A boolean probe would reopen the
            // exact cross-process race this lease exists to close.
            defer { recoveryLease.release() }

            guard let modified = try? partial.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate,
            now.timeIntervalSince(modified) >= compatibilityGrace
            else { continue }

            let payloadBytes: Int64
            do {
                payloadBytes = try repairAbandonedWAV(at: partial)
            } catch let error as CocoaError where error.code == .fileReadCorruptFile {
                // Structural corruption is permanent and proven. Storage,
                // fsync, and rename failures are handled below without ever
                // reclassifying recoverable voice as corruption.
                try? fileManager.removeItem(at: partial)
                continue
            } catch {
                // Header repair may already have made progress. Keep the exact
                // source path so a later launch can retry after transient I/O.
                continue
            }

            guard DictationDurationPolicy.isWorthTranscribing(
                duration: TimeInterval(payloadBytes) / TimeInterval(Self.bytesPerSecond)
            ) else {
                try fileManager.removeItem(at: partial)
                continue
            }

            if fileManager.fileExists(atPath: final.path) {
                do {
                    let finalBytes = try writerWAVPayloadBytes(at: final)
                    guard DictationDurationPolicy.isWorthTranscribing(
                        duration: TimeInterval(finalBytes) / TimeInterval(Self.bytesPerSecond)
                    ) else {
                        // A too-short final cannot supersede a useful partial.
                        try fileManager.removeItem(at: final)
                        try publishMemoryPartial(
                            partial,
                            to: final,
                            promoted: &promoted
                        )
                        continue
                    }
                    // The already-published final is structurally complete;
                    // retaining a duplicate partial adds no recovery value.
                    try? fileManager.removeItem(at: partial)
                    promoted.insert(final.standardizedFileURL)
                } catch let error as CocoaError where error.code == .fileReadCorruptFile {
                    // Never discard the known-valid partial for an invalid
                    // collision. Replace only if removal actually succeeds.
                    try? fileManager.removeItem(at: final)
                    if !fileManager.fileExists(atPath: final.path) {
                        try publishMemoryPartial(
                            partial,
                            to: final,
                            promoted: &promoted
                        )
                    }
                } catch {
                    // A transient read of the existing final proves nothing;
                    // retain both candidates for the next launch.
                }
            } else {
                try publishMemoryPartial(
                    partial,
                    to: final,
                    promoted: &promoted
                )
            }
        }
        return promoted
    }

    private func publishMemoryPartial(
        _ partial: URL,
        to final: URL,
        promoted: inout Set<URL>
    ) throws {
        do {
            try partialMover(partial, final)
            promoted.insert(final.standardizedFileURL)
        } catch {
            // Some filesystem wrappers report an error after an atomic rename
            // became visible. A previously validated source that disappeared
            // while the exact final appeared has crossed the commit point.
            if !fileManager.fileExists(atPath: partial.path),
               fileManager.fileExists(atPath: final.path) {
                promoted.insert(final.standardizedFileURL)
                return
            }
            // Before-effect or ambiguous failure: retain whichever candidate
            // exists. The caller intentionally continues launch reconciliation.
        }
    }

    /// A `.pending` marker is a keep/reconciliation lease. A crash may happen
    /// before the source move, after it, or while the foreground stops waiting;
    /// none of those phases authorizes deleting voice after a technical error.
    /// Fresh leases may belong to another running app instance. Old leases are
    /// simply cleared; a source in Takes is then handled by normal crash import
    /// and a destination in Recovery remains available for Retry.
    private func reconcilePendingTransactions(from takesDirectory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let prefix = ".openramble-recovery-"
        let suffix = ".pending"
        for marker in entries {
            let name = marker.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            if let modified = try? marker.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate,
               Date().timeIntervalSince(modified) < compatibilityGrace {
                continue
            }
            try? fileManager.removeItem(at: marker)
        }
    }

    /// Byte rate of our own WAVWriter stream: 16 kHz × 16-bit × mono.
    /// The format is pinned by the header check in `repairAbandonedWAV`.
    private static let bytesPerSecond: Int64 = 32_000

    /// WAVWriter first puts a 44-byte header with zero dimensions and
    /// fixes them in `close()`. After kill/crash PCM is already on the disk, but without
    /// of this fix, the system decoder considers the entry empty. We only accept
    /// the exact format of the writer's own: someone else's or cropped file should not
    /// masquerade as a suitable Retry.
    ///
    /// Returns the PCM payload size: it decides whether the recording holds
    /// anything worth transcribing.
    @discardableResult
    private func repairAbandonedWAV(at url: URL) throws -> Int64 {
        let payloadBytes = try writerWAVPayloadBytes(at: url)
        let handle = try FileHandle(forUpdating: url)
        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: littleEndian(UInt32(36 + payloadBytes)))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: littleEndian(UInt32(payloadBytes)))
            try wavSynchronizer(handle)
            try handle.close()
        } catch {
            // The close error should be visible, but re-closing after an
            // earlier error only releases the descriptor.
            try? handle.close()
            throw error
        }
        return payloadBytes
    }

    /// Read-only structural validation for an exact WAVWriter artifact.
    /// Storage errors remain distinguishable from proven format corruption.
    private func writerWAVPayloadBytes(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        let totalBytes = fileSize.int64Value
        guard totalBytes >= 44 else { throw CocoaError(.fileReadCorruptFile) }
        let payloadBytes = totalBytes - 44
        guard payloadBytes.isMultiple(of: 2), payloadBytes <= Int64(UInt32.max) - 36 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let handle = try FileHandle(forReadingFrom: url)
        do {
            try handle.seek(toOffset: 0)
            guard let header = try handle.read(upToCount: 44), header.count == 44,
                  String(decoding: header[0..<4], as: UTF8.self) == "RIFF",
                  String(decoding: header[8..<16], as: UTF8.self) == "WAVEfmt ",
                  readUInt32(header, at: 16) == 16,
                  readUInt16(header, at: 20) == 1,
                  readUInt16(header, at: 22) == 1,
                  readUInt32(header, at: 24) == 16_000,
                  readUInt32(header, at: 28) == 32_000,
                  readUInt16(header, at: 32) == 2,
                  readUInt16(header, at: 34) == 16,
                  String(decoding: header[36..<40], as: UTF8.self) == "data"
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        return payloadBytes
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    public func recordings() throws -> [URL] {
        guard !automaticRecoveryIsFaulted(
            sourceDirectory: directory.deletingLastPathComponent().appending(
                path: "Takes",
                directoryHint: .isDirectory
            )
        ) else { return [] }
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let siblingTakes = directory.deletingLastPathComponent().appending(
            path: "Takes",
            directoryHint: .isDirectory
        )
        let allowedParents = Set([
            directory.standardizedFileURL,
            siblingTakes.standardizedFileURL
        ])
        let tombstonedRecovery = try reconcileDeletionIntents(
            in: directory,
            allowedTargetParents: allowedParents
        )
        let tombstonedTakes = try reconcileDeletionIntents(
            in: siblingTakes,
            allowedTargetParents: allowedParents
        )
        let tombstoned = tombstonedRecovery.union(tombstonedTakes)
        return try entries()
            .filter { !tombstoned.contains($0.url.standardizedFileURL) }
            .sorted { $0.date > $1.date }
            .map(\.url)
    }

    public func delete(_ url: URL) throws {
        let prefix = directory.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.removeItem(at: url)
    }

    private struct Entry {
        let url: URL
        let date: Date
        let bytes: Int64
    }

    private func entries() throws -> [Entry] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        return try urls.filter {
            $0.pathExtension.lowercased() == "wav" && !hasDeletionIntent(for: $0)
        }.map { url in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values.contentModificationDate, let size = values.fileSize else {
                throw CocoaError(.fileReadUnknown)
            }
            return Entry(url: url, date: date, bytes: Int64(size))
        }
    }

    private func prune(now: Date = Date()) throws {
        var survivors: [Entry] = []
        for entry in try entries().sorted(by: { $0.date < $1.date }) {
            if now.timeIntervalSince(entry.date) > maximumAge {
                try fileManager.removeItem(at: entry.url)
            } else {
                survivors.append(entry)
            }
        }

        var totalBytes = survivors.reduce(Int64(0)) { $0 + $1.bytes }
        while survivors.count > maximumCount || totalBytes > maximumBytes {
            let oldest = survivors.removeFirst()
            try fileManager.removeItem(at: oldest.url)
            totalBytes -= oldest.bytes
        }
    }

    private func automaticRecoveryIsFaulted(sourceDirectory: URL) -> Bool {
        RecordingFileDisposer.shared.isStorageFaulted(in: sourceDirectory)
            || RecordingFileDisposer.shared.isStorageFaulted(in: directory)
            || RecordingDeletionIntent.hasStorageFault(
                in: sourceDirectory,
                fileManager: fileManager
            )
            || RecordingDeletionIntent.hasStorageFault(
                in: directory,
                fileManager: fileManager
            )
    }
}

/// Old unit tests and pure consumers can explicitly choose to remove WAV.
public struct DiscardingRecordingRecovery: RecordingRecoveryStoring {
    public init() {}

    public func preserve(_ source: URL) throws -> URL? {
        try FileManager.default.removeItem(at: source)
        return nil
    }
}
