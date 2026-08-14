import Foundation
import XCTest
@testable import DictationCore

final class RecordingFileDisposerTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let condition = NSCondition()
        private var blocked = true
        private var entered = false
        private var removed: [URL] = []

        func remove(_ url: URL) {
            condition.lock()
            if !entered {
                entered = true
                condition.broadcast()
                while blocked { condition.wait() }
            }
            removed.append(url)
            condition.broadcast()
            condition.unlock()
        }

        func waitUntilEntered() {
            condition.lock()
            while !entered { condition.wait() }
            condition.unlock()
        }

        func release() {
            condition.lock()
            blocked = false
            condition.broadcast()
            condition.unlock()
        }

        func snapshot() -> [URL] {
            condition.lock()
            defer { condition.unlock() }
            return removed
        }
    }

    private final class BlockingIntentProbe: @unchecked Sendable {
        private let condition = NSCondition()
        private var first = true
        private var blocked = true

        func persist(_ urls: [URL]) -> [URL]? {
            condition.lock()
            if first {
                first = false
                condition.broadcast()
                while blocked { condition.wait() }
            }
            condition.unlock()
            return urls
        }

        func waitUntilEntered() {
            condition.lock()
            while first { condition.wait() }
            condition.unlock()
        }

        func release() {
            condition.lock()
            blocked = false
            condition.broadcast()
            condition.unlock()
        }
    }

    func testTransactionBatchNeverDropsOneOfItsPaths() async throws {
        let probe = Probe()
        let disposer = RecordingFileDisposer(remove: probe.remove)
        let root = URL(fileURLWithPath: "/tmp/disposer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appending(path: "blocker")
        let batch = ["raw.wav", "committed.wav", "marker.pending"].map {
            root.appending(path: $0)
        }
        for url in batch { try Data([7]).write(to: url) }

        disposer.submit(blocker)
        await Task.detached { probe.waitUntilEntered() }.value
        disposer.submit(batch)

        let intentDeadline = Date().addingTimeInterval(2)
        while Date() < intentDeadline,
              !FileManager.default.fileExists(
                atPath: RecordingDeletionIntent.markerURL(for: batch[0]).path
              ) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: RecordingDeletionIntent.markerURL(for: batch[0]).path
            ),
            "the durable lane must run while unlink is wedged"
        )
        XCTAssertLessThanOrEqual(disposer.retainedOperationCount, 5)
        XCTAssertLessThanOrEqual(disposer.retainedPathCount, 6)

        probe.release()
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, probe.snapshot().count < 4 {
            try await Task.sleep(for: .milliseconds(5))
        }
        while Date() < deadline, disposer.retainedOperationCount != 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(probe.snapshot(), [blocker] + batch)
        XCTAssertEqual(disposer.retainedOperationCount, 0)
        XCTAssertEqual(disposer.retainedPathCount, 0)
    }

    func testPermanentWedgeKeepsTaskAndPathMemoryBounded() async {
        let probe = Probe()
        let maximumBatches = 16
        let disposer = RecordingFileDisposer(
            maximumPendingBatches: maximumBatches,
            remove: probe.remove
        )
        let root = URL(fileURLWithPath: "/tmp/disposer-bound-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        disposer.submit(root.appending(path: "blocker"))
        await Task.detached { probe.waitUntilEntered() }.value
        for index in 0..<10_000 {
            disposer.submit([
                root.appending(path: "\(index)-raw.wav"),
                root.appending(path: "\(index)-final.wav"),
                root.appending(path: "\(index)-marker.pending")
            ])
        }

        XCTAssertLessThanOrEqual(disposer.retainedOperationCount, 5)
        // One bounded marker queue (3 paths/batch) plus one bounded unlink
        // queue after two audio sidecars and one atomic batch manifest were
        // appended (6 paths/batch).
        XCTAssertLessThanOrEqual(disposer.retainedPathCount, maximumBatches * 9)
        probe.release()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, disposer.retainedOperationCount != 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(disposer.retainedOperationCount, 0)
    }

    func testSuccessfulDeleteRemovesAudioThenItsDurableIntent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "disposer-success-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appending(path: "take-success.wav")
        let marker = RecordingDeletionIntent.markerURL(for: audio)
        try Data(repeating: 4, count: 32).write(to: audio)
        let disposer = RecordingFileDisposer()

        disposer.submit(audio)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              FileManager.default.fileExists(atPath: audio.path)
                || FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(disposer.retainedOperationCount, 0)
    }

    func testFailedUnlinkLeavesExactDurableIntentForLaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "disposer-failed-unlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appending(path: "take-private.wav")
        let marker = RecordingDeletionIntent.markerURL(for: audio)
        try Data(repeating: 5, count: 32).write(to: audio)
        let disposer = RecordingFileDisposer(remove: { _ in })

        disposer.submit(audio)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, disposer.retainedOperationCount != 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(
            RecordingDeletionIntent.targetURL(for: marker),
            audio,
            "intent must be durable and exact before a failing unlink returns"
        )
    }

    func testAcknowledgementResolvesOnlyAfterExactIntentIsDurable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "disposer-ack-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let late = root.appending(path: "take-not-created-yet.wav")
        let marker = RecordingDeletionIntent.markerURL(for: late)
        let disposer = RecordingFileDisposer()

        let durable = await disposer.submitAcknowledged([late]).value()

        XCTAssertTrue(durable)
        XCTAssertEqual(RecordingDeletionIntent.targetURL(for: marker), late)
    }

    func testQueueSaturationReturnsFailedAckAndPersistsNonDeletingStorageFault() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "disposer-storage-fault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = BlockingIntentProbe()
        let disposer = RecordingFileDisposer(
            maximumPendingBatches: 2,
            remove: { _ in },
            intentPersistence: probe.persist
        )

        disposer.submit(root.appending(path: "take-blocking.wav"))
        await Task.detached { probe.waitUntilEntered() }.value
        let displaced = disposer.submitAcknowledged([
            root.appending(path: "take-displaced.wav")
        ])
        disposer.submit(root.appending(path: "take-pending.wav"))
        disposer.submit(root.appending(path: "take-overflow.wav"))

        let acknowledged = await displaced.value()
        XCTAssertFalse(acknowledged)
        probe.release()

        let marker = RecordingDeletionIntent.storageFaultMarker(in: root)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              !RecordingDeletionIntent.hasStorageFault(in: root) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(RecordingDeletionIntent.hasStorageFault(in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(disposer.isStorageFaulted(in: root))
    }
}
