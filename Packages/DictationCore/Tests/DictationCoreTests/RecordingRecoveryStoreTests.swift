import XCTest
@testable import DictationCore

final class RecordingRecoveryStoreTests: XCTestCase {
    private var root: URL!
    private var takes: URL!
    private var recovered: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "recording-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        takes = root.appending(path: "Takes", directoryHint: .isDirectory)
        recovered = root.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func take(_ name: String, bytes: Int = 8) throws -> URL {
        let url = takes.appending(path: name)
        try Data(repeating: 7, count: bytes).write(to: url)
        try backdate(url)
        return url
    }

    /// A crash leftover is old by the time the app relaunches; a fresh file is
    /// protected by the live-recording guard and must be aged explicitly.
    private func backdate(_ url: URL, by seconds: TimeInterval = 120) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)],
            ofItemAtPath: url.path
        )
    }

    /// Header that WAVWriter managed to write before process kill: format
    /// is already valid, but the dimensions are still zero, although the PCM payload is on disk.
    private func abandonedWAV(_ name: String, sampleBytes: Int = 3200) throws -> URL {
        var data = Data()
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        u32(36) // process died before the final close
        data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16)
        u16(1)
        u16(1)
        u32(16_000)
        u32(32_000)
        u16(2)
        u16(16)
        data.append(contentsOf: "data".utf8)
        u32(0) // process died before the final close
        data.append(Data(repeating: 7, count: sampleBytes))
        let url = takes.appending(path: name)
        try data.write(to: url)
        try backdate(url)
        return url
    }

    /// A take written moments ago may be the live recording of another
    /// running instance sharing this folder (debug build next to the release
    /// build). The import must leave it exactly where it is — repairing or
    /// deleting it would steal the file out from under the recorder
    /// mid-dictation.
    func testImportLeavesFreshTakeAloneItMayBeALiveRecording() async throws {
        let store = RecordingRecoveryStore(directory: recovered)
        let live = takes.appending(path: "take-live.wav")
        try Data(repeating: 7, count: 64_000).write(to: live)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertEqual(result.discardedCorruptCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: live.path),
            "a possibly-live take must stay in place, byte for byte"
        )
        let kept = try await store.recordings()
        XCTAssertTrue(kept.isEmpty)
    }

    func testFreshTakeIsRescannedAfterGraceWithoutRelaunch() async throws {
        let fresh = try abandonedWAV("take-fresh-crash.wav", sampleBytes: 32_000)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fresh.path
        )
        let store = RecordingRecoveryStore(
            directory: recovered,
            compatibilityGrace: 0.05,
            maintenanceRetryDelay: 0.01,
            idleScanInterval: 0.02
        )

        let initial = try await store.importAbandoned(from: takes)
        XCTAssertTrue(initial.recordings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))

        let deadline = Date().addingTimeInterval(2)
        var recoveredFiles: [URL] = []
        while Date() < deadline {
            recoveredFiles = try await store.recordings()
            if recoveredFiles.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(recoveredFiles.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testAutomaticRescanStillWaitsForExclusiveWriterLease() async throws {
        let live = try abandonedWAV("take-live-across-rescan.wav", sampleBytes: 32_000)
        let handle = try FileHandle(forWritingTo: live)
        try RecordingFileLease.acquireExclusive(on: handle)
        let store = RecordingRecoveryStore(
            directory: recovered,
            compatibilityGrace: 0,
            maintenanceRetryDelay: 0.01,
            idleScanInterval: 0.02
        )

        _ = try await store.importAbandoned(from: takes)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        let whileLeased = try await store.recordings()
        XCTAssertTrue(whileLeased.isEmpty)

        try handle.close()
        let deadline = Date().addingTimeInterval(2)
        var recoveredFiles: [URL] = []
        while Date() < deadline {
            recoveredFiles = try await store.recordings()
            if recoveredFiles.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(recoveredFiles.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }

    func testFreshPartialAndPendingMarkerAreReconciledInProcess() async throws {
        let partial = try abandonedWAV(
            "memory-recovery-fresh-rescan.wav.partial",
            sampleBytes: 32_000
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: partial.path
        )
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        let pending = recovered.appending(
            path: ".openramble-recovery-\(UUID().uuidString.lowercased()).pending"
        )
        try Data("source.wav".utf8).write(to: pending)
        let store = RecordingRecoveryStore(
            directory: recovered,
            compatibilityGrace: 0.05,
            maintenanceRetryDelay: 0.01,
            idleScanInterval: 0.02
        )

        _ = try await store.importAbandoned(from: takes)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try await store.recordings().count == 1,
               !FileManager.default.fileExists(atPath: pending.path) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reconciled = try await store.recordings()
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testKernelLeaseProtectsBackdatedLiveTakeUntilItsWriterDies() async throws {
        let live = try abandonedWAV("take-live-but-stale.wav", sampleBytes: 32_000)
        let handle = try FileHandle(forWritingTo: live)
        try RecordingFileLease.acquireExclusive(on: handle)
        let store = RecordingRecoveryStore(directory: recovered)

        let whileLive = try await store.importAbandoned(from: takes)

        XCTAssertEqual(whileLive.newlyImportedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        try handle.close()

        let afterOwnerExit = try await store.importAbandoned(from: takes)
        XCTAssertEqual(afterOwnerExit.newlyImportedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        XCTAssertEqual(afterOwnerExit.recordings.count, 1)
    }

    func testKernelLeaseProtectsBackdatedMemoryPartialUntilWriterCloses() async throws {
        let partial = try abandonedWAV(
            "memory-recovery-live.wav.partial",
            sampleBytes: 32_000
        )
        let final = partial.deletingPathExtension()
        let handle = try FileHandle(forWritingTo: partial)
        try RecordingFileLease.acquireExclusive(on: handle)
        let store = RecordingRecoveryStore(directory: recovered)

        let whileLive = try await store.importAbandoned(from: takes)

        XCTAssertEqual(whileLive.newlyImportedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        try handle.close()

        let afterOwnerExit = try await store.importAbandoned(from: takes)
        XCTAssertEqual(afterOwnerExit.newlyImportedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertEqual(afterOwnerExit.recordings.count, 1)
    }

    func testImportHoldsItsLeaseContinuouslyThroughRawRepairAndMove() async throws {
        let live = try abandonedWAV("take-claimed-through-repair.wav", sampleBytes: 32_000)
        let takesURL = try XCTUnwrap(takes)
        let enteredRepair = DispatchSemaphore(value: 0)
        let allowRepair = DispatchSemaphore(value: 0)
        let store = RecordingRecoveryStore(
            directory: recovered,
            wavSynchronizer: { handle in
                enteredRepair.signal()
                _ = allowRepair.wait(timeout: .now() + 2)
                try handle.synchronize()
            },
            partialMover: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )
        let importing = Task {
            try await store.importAbandoned(from: takesURL)
        }

        XCTAssertEqual(enteredRepair.wait(timeout: .now() + 1), .success)
        defer { allowRepair.signal() }
        let lateWriter = try FileHandle(forWritingTo: live)
        defer { try? lateWriter.close() }
        XCTAssertThrowsError(try RecordingFileLease.acquireExclusive(on: lateWriter))
        allowRepair.signal()

        let result = try await importing.value
        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }

    func testImportHoldsItsLeaseContinuouslyThroughPartialPublish() async throws {
        let partial = try abandonedWAV(
            "memory-recovery-claimed-through-publish.wav.partial",
            sampleBytes: 32_000
        )
        let takesURL = try XCTUnwrap(takes)
        let enteredMove = DispatchSemaphore(value: 0)
        let allowMove = DispatchSemaphore(value: 0)
        let store = RecordingRecoveryStore(
            directory: recovered,
            wavSynchronizer: { try $0.synchronize() },
            partialMover: { source, destination in
                enteredMove.signal()
                _ = allowMove.wait(timeout: .now() + 2)
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )
        let importing = Task {
            try await store.importAbandoned(from: takesURL)
        }

        XCTAssertEqual(enteredMove.wait(timeout: .now() + 1), .success)
        defer { allowMove.signal() }
        let lateWriter = try FileHandle(forWritingTo: partial)
        defer { try? lateWriter.close() }
        XCTAssertThrowsError(try RecordingFileLease.acquireExclusive(on: lateWriter))
        allowMove.signal()

        let result = try await importing.value
        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testPreserveMovesWAVOutOfActiveTakes() async throws {
        let source = try take("failed.wav")
        let store = RecordingRecoveryStore(directory: recovered)

        let preserved = try await store.preserve(source)
        let destination = try XCTUnwrap(preserved)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 7, count: 8))
    }

    func testTransactionalPreserveCommitsWithoutForegroundPublication() async throws {
        let source = try take("transaction.wav", bytes: 32)
        let store = RecordingRecoveryStore(directory: recovered)

        let ticket = store.beginPreserve(source)
        let outcome = await ticket.value()

        guard case let .committed(destination) = outcome else {
            return XCTFail("expected committed transaction, got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 7, count: 32))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path),
            "a UI timeout must not make late technical recovery disappear"
        )
    }

    func testPublishedTransactionImmediatelyRefreshesMaintenanceObservers() async throws {
        let store = RecordingRecoveryStore(
            directory: recovered,
            maintenanceRetryDelay: 10,
            idleScanInterval: 10
        )
        _ = try await store.importAbandoned(from: takes)
        let results = await store.maintenanceResults()
        let published = expectation(description: "published recovery is visible without idle scan")
        let observer = Task {
            for await result in results {
                if result.recordings.contains(where: {
                    $0.lastPathComponent.contains("recording-")
                }) {
                    published.fulfill()
                    return
                }
            }
        }
        defer { observer.cancel() }

        let source = try take("late-visible.wav", bytes: 32)
        let ticket = store.beginPreserve(source)
        guard case .committed = await ticket.value() else {
            return XCTFail("expected committed recovery transaction")
        }
        ticket.markPublished()

        await fulfillment(of: [published], timeout: 0.2)
    }

    func testTransactionDeleteDispositionRemovesSourceDestinationAndMarkerAsOneBatch() async throws {
        let source = try take("cancelled.wav", bytes: 32)
        let store = RecordingRecoveryStore(directory: recovered)

        let ticket = store.beginPreserve(source)
        ticket.requestDelete()
        let outcome = await ticket.value()
        XCTAssertEqual(outcome, .deleted)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              FileManager.default.fileExists(atPath: source.path)
                || FileManager.default.fileExists(atPath: ticket.destinationURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ticket.destinationURL.path))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: recovered.path)) ?? []
        XCTAssertFalse(entries.contains { $0.hasSuffix(".pending") })
    }

    func testTransactionCanAcknowledgeFsyncedDeleteIntent() async throws {
        let source = try take("durable-cancel.wav", bytes: 32)
        let store = RecordingRecoveryStore(directory: recovered)
        let ticket = store.beginPreserve(source)

        let durable = await ticket.requestDeleteDurably()

        XCTAssertTrue(durable)
        let sourceMarker = RecordingDeletionIntent.markerURL(for: source)
        let destinationMarker = RecordingDeletionIntent.markerURL(for: ticket.destinationURL)
        XCTAssertTrue(
            RecordingDeletionIntent.targetURL(for: sourceMarker) == source
                || RecordingDeletionIntent.targetURL(for: destinationMarker)
                    == ticket.destinationURL,
            "an absent late-create path must retain an exact durable intent"
        )
    }

    func testFailedTransactionNeverDeletesTheSourceOnNextLaunch() async throws {
        let source = try take("must-survive.wav", bytes: 32)
        try Data("not a directory".utf8).write(to: recovered)
        let store = RecordingRecoveryStore(directory: recovered)

        let outcome = await store.beginPreserve(source).value()

        guard case let .notCommitted(sourceRemains, _) = outcome else {
            return XCTFail("expected a failed transaction, got \(outcome)")
        }
        XCTAssertTrue(sourceRemains)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testStaleKeepMarkerNeverDeletesACommittedRecoveryWAV() async throws {
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let destination = recovered.appending(path: "recording-test-\(id).wav")
        let marker = recovered.appending(path: ".openramble-recovery-\(id).pending")
        try Data(repeating: 9, count: 32).write(to: destination)
        try Data("old-source.wav".utf8).write(to: marker)
        try backdate(marker)
        let store = RecordingRecoveryStore(directory: recovered)

        _ = try await store.importAbandoned(from: takes)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testExactDeleteIntentPurgesCancelledTakeAndNeverImportsIt() async throws {
        let cancelled = try abandonedWAV("take-cancelled.wav", sampleBytes: 32_000)
        let marker = try RecordingDeletionIntent.persist(for: cancelled)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "present-to-absent is proof that this exact creator published and was purged"
        )
    }

    func testBackdatedAbsentIntentNeverExpiresBeforeAnUnboundedLateCreate() async throws {
        let late = takes.appending(path: "take-unbounded-late.wav")
        let marker = try RecordingDeletionIntent.persist(for: late)
        try backdate(marker, by: 24 * 3600)
        let store = RecordingRecoveryStore(directory: recovered)

        _ = try await store.importAbandoned(from: takes)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "wall-clock age cannot prove a non-cancellable creator returned"
        )

        _ = try abandonedWAV("take-unbounded-late.wav", sampleBytes: 32_000)
        let result = try await store.importAbandoned(from: takes)
        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStorageFaultNeverDeletesOrImportsAmbiguousFutureRecording() async throws {
        try RecordingDeletionIntent.persistStorageFault(in: takes)
        let canceledButUnjournaled = try abandonedWAV(
            "take-canceled-before-storage-fault.wav",
            sampleBytes: 32_000
        )
        let futureTechnical = try abandonedWAV(
            "take-technical-after-storage-fault.wav",
            sampleBytes: 32_000
        )
        let canceledBefore = try Data(contentsOf: canceledButUnjournaled)
        let technicalBefore = try Data(contentsOf: futureTechnical)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertTrue(result.storageFaulted)
        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: canceledButUnjournaled), canceledBefore)
        XCTAssertEqual(try Data(contentsOf: futureTechnical), technicalBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canceledButUnjournaled.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: futureTechnical.path))
    }

    func testAbsentAtDeleteThenLateCreateCannotEscapeFreshIntent() async throws {
        let late = takes.appending(path: "take-late-create.wav")
        let marker = RecordingDeletionIntent.markerURL(for: late)
        let disposer = RecordingFileDisposer()

        // Capture registered the path, Escape won, but non-cancellable open
        // has not returned yet. ENOENT must not be mistaken for completion.
        disposer.submit(late)
        let intentDeadline = Date().addingTimeInterval(2)
        while Date() < intentDeadline, disposer.retainedOperationCount != 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        _ = try abandonedWAV("take-late-create.wav", sampleBytes: 32_000)
        let store = RecordingRecoveryStore(directory: recovered)
        let result = try await store.importAbandoned(from: takes)

        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDeleteIntentIsExactAndTechnicalCrashTakeStillImports() async throws {
        let cancelled = try abandonedWAV("take-cancelled.wav", sampleBytes: 32_000)
        let technical = try abandonedWAV("take-technical-crash.wav", sampleBytes: 32_000)
        _ = try RecordingDeletionIntent.persist(for: cancelled)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: technical.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.recordings.first)).count, 32_044)
    }

    func testAtomicBatchManifestProtectsCrossDirectoryMoveBeforeSidecarsExist() async throws {
        let source = try abandonedWAV("take-moving-cancel.wav", sampleBytes: 32_000)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        let destination = recovered.appending(path: "recording-moving-cancel.wav")
        try Data(contentsOf: source).write(to: destination)
        let unrelated = try abandonedWAV("take-technical-unrelated.wav", sampleBytes: 32_000)

        // Crash phase: the one atomic batch manifest is durable, but neither
        // exact per-path sidecar has been written yet.
        let batchMarker = try XCTUnwrap(
            try RecordingDeletionIntent.persistBatch(for: [source, destination])
        )
        XCTAssertEqual(batchMarker.deletingLastPathComponent(), takes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: RecordingDeletionIntent.markerURL(for: source).path
            )
        )
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertEqual(result.recordings.count, 1)
    }

    func testCrossDirectoryManifestFiltersDestinationWhenLaunchUnlinkFails() async throws {
        let source = try abandonedWAV("take-moving-locked.wav", sampleBytes: 32_000)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        let destination = recovered.appending(path: "recording-moving-locked.wav")
        try Data(contentsOf: source).write(to: destination)
        _ = try RecordingDeletionIntent.persistBatch(for: [source, destination])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: recovered.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: recovered.path
            )
        }
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)
        let laterListing = try await store.recordings()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path),
            "the fixture must prove unlink really failed"
        )
        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertTrue(laterListing.isEmpty, "public listings must rediscover Takes manifest")
    }

    func testStaleSealedMemoryPartialIsRepairedPromotedAndImported() async throws {
        let partial = try abandonedWAV(
            "memory-recovery-crash.wav.partial",
            sampleBytes: 32_000
        )
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.recordings.first)).count, 32_044)
    }

    func testTransientPartialSynchronizeFailureRetainsVoiceForNextLaunch() async throws {
        enum InjectedFailure: Error { case synchronize }
        let partial = try abandonedWAV(
            "memory-recovery-sync-transient.wav.partial",
            sampleBytes: 32_000
        )
        let failing = RecordingRecoveryStore(
            directory: recovered,
            wavSynchronizer: { _ in throw InjectedFailure.synchronize },
            partialMover: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )

        let first = try await failing.importAbandoned(from: takes)

        XCTAssertTrue(first.recordings.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partial.path),
            "a transient fsync error is not proof of corruption"
        )

        try backdate(partial)
        let nextLaunch = RecordingRecoveryStore(directory: recovered)
        let recoveredResult = try await nextLaunch.importAbandoned(from: takes)
        XCTAssertEqual(recoveredResult.newlyImportedCount, 1)
        XCTAssertEqual(recoveredResult.recordings.count, 1)
    }

    func testTransientPartialRenameFailureBeforeEffectRetainsVoiceForNextLaunch() async throws {
        enum InjectedFailure: Error { case rename }
        let partial = try abandonedWAV(
            "memory-recovery-rename-before.wav.partial",
            sampleBytes: 32_000
        )
        let failing = RecordingRecoveryStore(
            directory: recovered,
            wavSynchronizer: { try $0.synchronize() },
            partialMover: { _, _ in throw InjectedFailure.rename }
        )

        let first = try await failing.importAbandoned(from: takes)

        XCTAssertTrue(first.recordings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        try backdate(partial)
        let nextLaunch = RecordingRecoveryStore(directory: recovered)
        let recoveredResult = try await nextLaunch.importAbandoned(from: takes)
        XCTAssertEqual(recoveredResult.newlyImportedCount, 1)
        XCTAssertEqual(recoveredResult.recordings.count, 1)
    }

    func testRenameErrorAfterAtomicSideEffectReconcilesPublishedFinal() async throws {
        enum InjectedFailure: Error { case afterRename }
        let partial = try abandonedWAV(
            "memory-recovery-rename-after.wav.partial",
            sampleBytes: 32_000
        )
        let final = partial.deletingPathExtension()
        let failing = RecordingRecoveryStore(
            directory: recovered,
            wavSynchronizer: { try $0.synchronize() },
            partialMover: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
                throw InjectedFailure.afterRename
            }
        )

        let result = try await failing.importAbandoned(from: takes)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: final.path),
            "the reconciled final should continue through normal preservation"
        )
        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertEqual(result.recordings.count, 1)
    }

    func testCorruptExistingFinalNeverDisplacesKnownValidPartial() async throws {
        let partial = try abandonedWAV(
            "memory-recovery-final-collision.wav.partial",
            sampleBytes: 32_000
        )
        let final = partial.deletingPathExtension()
        try Data("corrupt".utf8).write(to: final)
        try backdate(final)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertEqual(result.recordings.count, 1)
    }

    func testFreshMemoryPartialMayBelongToAnotherInstanceAndIsUntouched() async throws {
        let partial = try abandonedWAV(
            "memory-recovery-live.wav.partial",
            sampleBytes: 32_000
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: partial.path
        )
        let before = try Data(contentsOf: partial)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: partial), before)
    }

    func testStaleTooShortAndMalformedMemoryPartialsArePurged() async throws {
        let short = try abandonedWAV(
            "memory-recovery-short.wav.partial",
            sampleBytes: 3_200
        )
        let malformed = try take("memory-recovery-malformed.wav.partial", bytes: 128)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: short.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
    }

    func testDeleteIntentForEitherMemoryPublicationNameWinsOverPartialRepair() async throws {
        let partial = try abandonedWAV(
            "memory-recovery-private.wav.partial",
            sampleBytes: 32_000
        )
        let final = partial.deletingPathExtension()
        _ = try RecordingDeletionIntent.persist(for: final)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    }

    func testImportAbandonedKeepsCrashRecordingForRetry() async throws {
        _ = try abandonedWAV("crash.wav", sampleBytes: 32_000)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)
        let recordings = result.recordings

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(result.discardedCorruptCount, 0)
        XCTAssertEqual(result.newlyImportedCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
        let data = try Data(contentsOf: XCTUnwrap(recordings.first))
        let riffSize = data[4..<8].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        let payloadSize = data[40..<44].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(riffSize, 36 + 32_000)
        XCTAssertEqual(payloadSize, 32_000)
    }

    func testCorruptFragmentDoesNotBlockValidCrashRecording() async throws {
        let corrupt = try take("corrupt.wav", bytes: 10)
        _ = try abandonedWAV("valid.wav", sampleBytes: 32_000)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.discardedCorruptCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
    }

    /// A too-short fragment is not "a recording after a failure" — it is an
    /// accidental key press that outlived a kill. The main dictation path
    /// deletes such takes silently; the import must behave the same. Otherwise
    /// the next launch shows "a recording is waiting" whose retry forever
    /// hits an empty result — an error out of thin air.
    func testImportDeletesTooShortFragmentSilently() async throws {
        _ = try abandonedWAV("blip.wav", sampleBytes: 3200) // 0.1 s — below the minimum
        _ = try abandonedWAV("empty.wav", sampleBytes: 0) // header without a single frame
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertEqual(
            result.discardedCorruptCount, 0,
            "A fragment is not corruption: no reason to scare with a damage message"
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: takes.path).isEmpty)
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: recovered.path)) ?? []
        XCTAssertTrue(saved.filter { $0.hasSuffix(".wav") }.isEmpty)
    }

    /// Exactly at the minimum — already recognizable, keep it.
    func testImportKeepsFragmentAtMinimumDuration() async throws {
        let minimumBytes = Int(DictationDurationPolicy.minimum * 32_000)
        _ = try abandonedWAV("edge.wav", sampleBytes: minimumBytes)
        let store = RecordingRecoveryStore(directory: recovered)

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.newlyImportedCount, 1)
    }

    /// A leftover from last week is not an event of this launch.
    ///
    /// The app used to announce "a recording was found after an interruption"
    /// on every start, even when the failure was a week old and nothing new
    /// happened: the person saw an error where there was none. The count of
    /// new imports lets the app tell "just rescued" from "old leftover".
    func testLeftoverFromPreviousLaunchIsNotCountedAsNew() async throws {
        let store = RecordingRecoveryStore(directory: recovered)
        _ = try await store.preserve(try take("old.wav", bytes: 64_000))

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertEqual(result.discardedCorruptCount, 0)
    }

    func testLimitsCountAndBytesOldestFirst() async throws {
        let store = RecordingRecoveryStore(
            directory: recovered,
            maximumCount: 2,
            maximumBytes: 12
        )
        for index in 0..<3 {
            let source = try take("\(index).wav", bytes: 6)
            _ = try await store.preserve(source)
            try await Task.sleep(for: .milliseconds(10))
        }

        let recordings = try await store.recordings()

        XCTAssertEqual(recordings.count, 2)
        let total = try recordings.reduce(0) {
            $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(total, 12)
    }

    func testDeletesEntriesOlderThanSevenDays() async throws {
        let store = RecordingRecoveryStore(directory: recovered)
        let old = try take("old.wav")
        _ = try await store.preserve(old)
        let before = try await store.recordings()
        let saved = try XCTUnwrap(before.first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: saved.path
        )

        _ = try await store.preserve(try take("new.wav"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        let remaining = try await store.recordings()
        XCTAssertEqual(remaining.count, 1)
    }

    /// Launch enforces retention even when nothing new is preserved.
    ///
    /// Preserving prunes too, but a quiet machine may not preserve anything
    /// for weeks — the import pass at launch is what keeps the retention
    /// promise ("kept for a few days") true.
    func testImportPrunesExpiredRecordingsWithoutNewPreserves() async throws {
        let store = RecordingRecoveryStore(directory: recovered)
        _ = try await store.preserve(try take("old.wav"))
        let before = try await store.recordings()
        let saved = try XCTUnwrap(before.first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: saved.path
        )

        let result = try await store.importAbandoned(from: takes)

        XCTAssertEqual(result.newlyImportedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        let remaining = try await store.recordings()
        XCTAssertTrue(remaining.isEmpty, "an expired recording must not outlive launch")
    }

    func testRetentionExpiresWhileAppStaysOpenAndQuiet() async throws {
        let store = RecordingRecoveryStore(
            directory: recovered,
            maximumAge: 0.08,
            maintenanceRetryDelay: 0.01,
            idleScanInterval: 0.02
        )
        _ = try await store.importAbandoned(from: takes)
        let source = takes.appending(path: "fresh-retention.wav")
        try Data(repeating: 7, count: 64).write(to: source)
        let preserved = try await store.preserve(source)
        let saved = try XCTUnwrap(preserved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, FileManager.default.fileExists(atPath: saved.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: saved.path),
            "retention maintenance must not require another preserve or relaunch"
        )
    }
}
