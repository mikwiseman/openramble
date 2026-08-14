import Darwin
import Foundation

/// On-disk proof that a user-owned recording must never be recovered.
///
/// The marker lives beside the recording and names only an adjacent basename.
/// That makes launch reconciliation exact: another app instance can help
/// finish deletion without ever following an arbitrary path from disk.
enum RecordingDeletionIntent {
    static let markerPrefix = ".openramble-delete-"
    static let batchMarkerPrefix = ".openramble-delete-batch-"
    static let markerSuffix = ".intent"
    static let storageFaultMarkerName = ".openramble-recovery-storage-fault"
    private static let payloadPrefix = "openramble-delete-v1\n"
    private static let storageFaultPayload = Data("openramble-recovery-storage-fault-v1\n".utf8)

    private struct BatchPayload: Codable {
        let version: Int
        let targets: [String]
    }

    static func owns(_ target: URL) -> Bool {
        let name = target.lastPathComponent.lowercased()
        return name.hasSuffix(".wav") || name.hasSuffix(".wav.partial")
    }

    static func markerURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appending(
            path: markerPrefix + target.lastPathComponent + markerSuffix,
            directoryHint: .notDirectory
        )
    }

    static func targetURL(for marker: URL, fileManager: FileManager = .default) -> URL? {
        let name = marker.lastPathComponent
        guard name.hasPrefix(markerPrefix), name.hasSuffix(markerSuffix),
              !name.hasPrefix(batchMarkerPrefix)
        else { return nil }
        let start = name.index(name.startIndex, offsetBy: markerPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -markerSuffix.count)
        let basename = String(name[start..<end])
        guard !basename.isEmpty, !basename.contains("/"), !basename.contains(":") else {
            return nil
        }
        let target = marker.deletingLastPathComponent().appending(
            path: basename,
            directoryHint: .notDirectory
        )
        guard owns(target),
              let data = fileManager.contents(atPath: marker.path),
              String(decoding: data, as: UTF8.self) == payloadPrefix + basename + "\n"
        else { return nil }
        return target
    }

    /// One atomic manifest closes the cross-path gap for recovery moves and
    /// memory publication (`raw`, `.partial`, final). Exact sidecars are still
    /// written afterward for cheap per-file lookup, but a crash between those
    /// writes cannot expose only half of the cancellation.
    static func persistBatch(
        for targets: [URL],
        fileManager: FileManager = .default
    ) throws -> URL? {
        let unique = orderedUnique(targets.filter(owns))
        guard unique.count > 1, let first = unique.first else { return nil }
        let marker = batchMarkerURL(for: unique, anchor: first.deletingLastPathComponent())
        try fileManager.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = BatchPayload(
            version: 1,
            targets: unique.map { $0.standardizedFileURL.path }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: marker, options: .atomic)
        try synchronizeFileAndParent(marker)
        return marker
    }

    static func batchTargets(
        for marker: URL,
        allowedParents: Set<URL>,
        fileManager: FileManager = .default
    ) -> [URL]? {
        let name = marker.lastPathComponent
        guard name.hasPrefix(batchMarkerPrefix), name.hasSuffix(markerSuffix),
              let data = fileManager.contents(atPath: marker.path), data.count <= 65_536,
              let payload = try? JSONDecoder().decode(BatchPayload.self, from: data),
              payload.version == 1, (2...16).contains(payload.targets.count)
        else { return nil }
        let targets = payload.targets.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        guard Set(targets).count == targets.count,
              targets.allSatisfy({ target in
                  owns(target)
                      && allowedParents.contains(
                        target.deletingLastPathComponent().standardizedFileURL
                      )
              }), let first = targets.first,
              batchMarkerURL(
                for: targets,
                anchor: first.deletingLastPathComponent()
              ).standardizedFileURL == marker.standardizedFileURL
        else { return nil }
        return targets
    }

    static func persist(for target: URL, fileManager: FileManager = .default) throws -> URL {
        precondition(owns(target))
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let marker = markerURL(for: target)
        let payload = Data((payloadPrefix + target.lastPathComponent + "\n").utf8)
        try payload.write(to: marker, options: .atomic)
        try synchronizeFileAndParent(marker)
        return marker
    }

    static func storageFaultMarker(in directory: URL) -> URL {
        directory.appending(path: storageFaultMarkerName, directoryHint: .notDirectory)
    }

    /// Persist a deterministic fail-safe after the bounded exact-intent queue
    /// saturates. Recovery never interprets this marker as permission to
    /// delete a directory. It refuses ambiguous automatic recovery and leaves
    /// every byte in place for explicit support/manual handling instead.
    static func persistStorageFault(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let marker = storageFaultMarker(in: directory)
        try storageFaultPayload.write(to: marker, options: .atomic)
        try synchronizeFileAndParent(marker)
    }

    static func hasStorageFault(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.contents(atPath: storageFaultMarker(in: directory).path)
            == storageFaultPayload
    }

    private static func synchronizeFileAndParent(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // `synchronize()` protects the marker contents. Syncing the parent
        // protects the atomic directory entry across power loss as well.
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func batchMarkerURL(for targets: [URL], anchor: URL) -> URL {
        // Stable FNV-1a is sufficient for a filename identity; the full exact
        // paths remain authenticated by recomputing this value during parse.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for target in targets {
            for byte in target.standardizedFileURL.path.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }
        let identity = String(hash, radix: 16, uppercase: false)
        return anchor.appending(
            path: batchMarkerPrefix + identity + markerSuffix,
            directoryHint: .notDirectory
        )
    }

    private static func orderedUnique(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }
}

private final class RecordingDeletionIntentReceiptState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate: Bool? = lock.withLock {
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func complete(_ value: Bool) {
        let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
            guard result == nil else { return [] }
            result = value
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: value) }
    }
}

/// Completion proof for the marker lane, not for best-effort unlink.
///
/// `true` means every audio URL in that submission was fsync-protected before
/// this value resolved. `false` means the bounded queue had to shed the exact
/// identifiers and entered an explicit storage-fault state; callers must not
/// claim that cancellation is durable in that case.
public final class RecordingDeletionIntentReceipt: @unchecked Sendable {
    private let state: RecordingDeletionIntentReceiptState

    fileprivate init(state: RecordingDeletionIntentReceiptState) {
        self.state = state
    }

    public func value() async -> Bool { await state.value() }
}

/// Best-effort deletion that can never hold the controller or microphone
/// actor inside a filesystem call.
///
/// Deletion has two independent, bounded lanes. The first persists an exact
/// intent sidecar; only then may the second call `removeItem`. Consequently a
/// permanently wedged unlink cannot hide the user's cancellation from launch
/// recovery. Pending unlink batches may be displaced to bound memory because
/// their durable sidecars remain the source of truth.
///
/// There is an unavoidable interval between a nonblocking `submit` call and
/// the marker worker reaching durable storage. Closing that interval would
/// require a filesystem syscall on the UI/capture caller. The product chooses
/// bounded UI latency; once deletion starts, however, intent is durable first.
public final class RecordingFileDisposer: @unchecked Sendable {
    public static let shared = RecordingFileDisposer()

    private struct IntentBatch {
        let urls: [URL]
        let receipt: RecordingDeletionIntentReceiptState?
    }

    private let lock = NSLock()
    private let remove: @Sendable (URL) -> Void
    private let exists: @Sendable (URL) -> Bool
    private let injectedIntentPersistence: (@Sendable ([URL]) -> [URL]?)?
    private let maximumPendingBatches: Int
    private var intentInFlight = false
    private var pendingIntentBatches: [IntentBatch] = []
    private var deletionInFlight = false
    private var pendingDeletionBatches: [[URL]] = []
    private var storageFaultDirectories: Set<URL> = []

    public init(
        maximumPendingBatches: Int = 128,
        remove: @escaping @Sendable (URL) -> Void = { url in
            try? FileManager.default.removeItem(at: url)
        },
        exists: @escaping @Sendable (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        intentPersistence: (@Sendable ([URL]) -> [URL]?)? = nil
    ) {
        precondition(maximumPendingBatches > 0)
        self.maximumPendingBatches = maximumPendingBatches
        self.remove = remove
        self.exists = exists
        injectedIntentPersistence = intentPersistence
    }

    /// Enqueue without waiting for the filesystem. The queue is physically
    /// bounded even if either a marker write or `removeItem` never returns.
    public func submit(_ url: URL) {
        submit([url])
    }

    /// Enqueue an indivisible ordered cleanup batch. Audio paths are protected
    /// by durable delete intents before the whole batch reaches unlink. Callers
    /// still put transaction audio first and keep markers last.
    public func submit(_ urls: [URL]) {
        enqueue(urls, receipt: nil)
    }

    /// Enqueue deletion and return proof that exact audio intent reached
    /// durable storage. The receipt deliberately does not wait for unlink.
    ///
    /// A false result is a real storage fault, not a timeout: exact path
    /// identity was displaced to preserve the queue's hard memory bound.
    public func submitAcknowledged(_ urls: [URL]) -> RecordingDeletionIntentReceipt {
        let state = RecordingDeletionIntentReceiptState()
        enqueue(urls, receipt: state)
        return RecordingDeletionIntentReceipt(state: state)
    }

    private func enqueue(
        _ urls: [URL],
        receipt: RecordingDeletionIntentReceiptState?
    ) {
        let unique = Self.orderedUnique(urls)
        guard !unique.isEmpty else {
            receipt?.complete(true)
            return
        }
        let submitted = IntentBatch(urls: unique, receipt: receipt)

        var shouldLaunch = false
        lock.withLock {
            if intentInFlight {
                if pendingIntentBatches.count == maximumPendingBatches {
                    // Once exact identifiers are shed there is no sound way to
                    // infer them later from mtime or a directory-wide cutoff.
                    // Enter an explicit storage fault instead: recovery keeps
                    // every ambiguous byte in place and exposes the failure,
                    // never deleting unrelated future technical recordings.
                    let displaced = pendingIntentBatches.removeFirst()
                    displaced.receipt?.complete(false)
                    recordStorageFault(for: displaced.urls)
                }
                pendingIntentBatches.append(submitted)
            } else {
                intentInFlight = true
                shouldLaunch = true
            }
        }

        if shouldLaunch {
            Task.detached(priority: .utility) { [self] in
                await drainIntents(startingWith: submitted)
            }
        }
    }

    private func drainIntents(startingWith first: IntentBatch) async {
        var batch = first
        var retryDelay: Duration = .milliseconds(100)
        while true {
            if let protected = persistIntents(for: batch.urls) {
                batch.receipt?.complete(true)
                enqueueDeletion(protected)
                retryDelay = .milliseconds(100)
            } else {
                // Keep one bounded worker retrying a returned storage error;
                // never delete audio whose intent could not be made durable,
                // and never require another user gesture to resume cleanup.
                persistStorageFaults()
                try? await Task.sleep(for: retryDelay)
                retryDelay = min(retryDelay * 2, .seconds(2))
                continue
            }

            persistStorageFaults()
            let next: IntentBatch? = lock.withLock {
                guard !pendingIntentBatches.isEmpty else {
                    intentInFlight = false
                    return nil
                }
                return pendingIntentBatches.removeFirst()
            }
            guard let next else { return }
            batch = next
        }
    }

    /// Returns the original ordered batch followed by its intent markers.
    private func persistIntents(for batch: [URL]) -> [URL]? {
        if let injectedIntentPersistence {
            return injectedIntentPersistence(batch)
        }
        var markers: [URL] = []
        do {
            let audioTargets = batch.filter(RecordingDeletionIntent.owns)
            let batchMarker = try RecordingDeletionIntent.persistBatch(for: audioTargets)
            for target in audioTargets {
                markers.append(try RecordingDeletionIntent.persist(for: target))
            }
            if let batchMarker { markers.append(batchMarker) }
            return batch + markers
        } catch {
            return nil
        }
    }

    private func recordStorageFault(for batch: [URL]) {
        for target in batch where RecordingDeletionIntent.owns(target) {
            let directory = target.deletingLastPathComponent().standardizedFileURL
            // Product paths use at most Takes and RecoveredAudio. Keep this
            // map bounded even if a hostile caller submits arbitrary folders.
            if storageFaultDirectories.count >= 8,
               !storageFaultDirectories.contains(directory) {
                continue
            }
            storageFaultDirectories.insert(directory)
        }
    }

    private func persistStorageFaults() {
        let snapshot: Set<URL> = lock.withLock { storageFaultDirectories }
        guard !snapshot.isEmpty else { return }
        var persisted: [URL] = []
        for directory in snapshot {
            do {
                try RecordingDeletionIntent.persistStorageFault(in: directory)
                persisted.append(directory)
            } catch {
                // Leave it coalesced for the next marker-lane pass.
            }
        }
        if !persisted.isEmpty {
            lock.withLock {
                for directory in persisted {
                    storageFaultDirectories.remove(directory)
                }
            }
        }
    }

    /// Includes both an in-memory saturation fault whose marker write is still
    /// pending and the durable marker observed after a restart.
    public func isStorageFaulted(in directory: URL) -> Bool {
        let normalized = directory.standardizedFileURL
        if lock.withLock({ storageFaultDirectories.contains(normalized) }) {
            return true
        }
        return RecordingDeletionIntent.hasStorageFault(in: normalized)
    }

    private func enqueueDeletion(_ batch: [URL]) {
        var shouldLaunch = false
        lock.withLock {
            if deletionInFlight {
                if pendingDeletionBatches.count == maximumPendingBatches {
                    // Safe to displace: the marker lane has already persisted
                    // every audio intent in this batch.
                    pendingDeletionBatches.removeFirst()
                }
                pendingDeletionBatches.append(batch)
            } else {
                deletionInFlight = true
                shouldLaunch = true
            }
        }
        if shouldLaunch {
            Task.detached(priority: .utility) { [self] in
                drainDeletion(startingWith: batch)
            }
        }
    }

    private func drainDeletion(startingWith first: [URL]) {
        var batch = first
        while true {
            let markerStart = batch.firstIndex {
                $0.lastPathComponent.hasPrefix(RecordingDeletionIntent.markerPrefix)
            } ?? batch.endIndex
            let originals = batch[..<markerStart]
            let markers = batch[markerStart...]
            var confirmedRemoved: Set<URL> = []

            // Preserve the caller's order: transaction audio before its keep
            // marker. Intent sidecars are removed only after their exact audio
            // target was observed to exist and then actually disappeared. An
            // ENOENT before a cancellation-deaf create is not completion: its
            // fresh sidecar must survive for launch reconciliation.
            for url in originals {
                let existedBefore = RecordingDeletionIntent.owns(url) && exists(url)
                remove(url)
                if existedBefore, !exists(url) {
                    confirmedRemoved.insert(url.standardizedFileURL)
                }
            }
            for marker in markers {
                if marker.lastPathComponent.hasPrefix(
                    RecordingDeletionIntent.batchMarkerPrefix
                ) {
                    let allAudioConfirmed = originals
                        .filter(RecordingDeletionIntent.owns)
                        .allSatisfy {
                            confirmedRemoved.contains($0.standardizedFileURL)
                        }
                    if allAudioConfirmed { remove(marker) }
                    continue
                }
                guard let target = RecordingDeletionIntent.targetURL(for: marker),
                      confirmedRemoved.contains(target.standardizedFileURL)
                else { continue }
                remove(marker)
            }

            let next: [URL]? = lock.withLock {
                guard !pendingDeletionBatches.isEmpty else {
                    deletionInFlight = false
                    return nil
                }
                return pendingDeletionBatches.removeFirst()
            }
            guard let next else { return }
            batch = next
        }
    }

    private static func orderedUnique(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.filter { seen.insert($0).inserted }
    }

    /// Test/diagnostic snapshot; contains counts only, never paths.
    public var retainedOperationCount: Int {
        lock.withLock {
            (intentInFlight ? 1 : 0)
                + (pendingIntentBatches.isEmpty ? 0 : 1)
                + (deletionInFlight ? 1 : 0)
                + (pendingDeletionBatches.isEmpty ? 0 : 1)
                + (storageFaultDirectories.isEmpty ? 0 : 1)
        }
    }

    /// Bounded diagnostic used by stress tests; paths themselves are never
    /// exposed to logs or telemetry.
    public var retainedPathCount: Int {
        lock.withLock {
            pendingIntentBatches.reduce(0) { $0 + $1.urls.count }
                + pendingDeletionBatches.reduce(0) { $0 + $1.count }
        }
    }
}
