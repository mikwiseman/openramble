import Foundation
import XCTest
@testable import DictationCore

final class RecordingDispositionTests: XCTestCase {
    private final class DeletionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[URL]] = []

        func remove(_ urls: [URL]) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            lock.withLock { batches.append(urls) }
        }

        var callCount: Int { lock.withLock { batches.count } }
    }

    func testAcceptedCancelDeletesRegisteredAndLateCreatedPaths() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "disposition-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appending(path: "raw.wav")
        let late = directory.appending(path: "late.wav")
        try Data([1]).write(to: raw)
        let probe = DeletionProbe()
        let disposition = RecordingDisposition(dispose: probe.remove)
        disposition.register([raw, late])

        XCTAssertTrue(disposition.requestDelete())
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        // Reproduce a cancellation-deaf creator returning after Escape.
        try Data([2]).write(to: late)
        disposition.register([late])

        XCTAssertEqual(disposition.state, .deleteRequested)
        XCTAssertEqual(probe.callCount, 2, "post-create re-registration must enqueue deletion again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    func testTechnicalKeepCanStillBecomeUserDeleteBeforePublication() {
        let disposition = RecordingDisposition()
        XCTAssertTrue(disposition.keepInBackground())
        XCTAssertTrue(disposition.requestDelete())
        XCTAssertEqual(disposition.state, .deleteRequested)
        XCTAssertFalse(disposition.markPublished())
    }

    func testPublishedRecoveryRequiresExplicitStoreDelete() {
        let disposition = RecordingDisposition()
        XCTAssertTrue(disposition.keepInBackground())
        XCTAssertTrue(disposition.markPublished())
        XCTAssertFalse(disposition.requestDelete())
        XCTAssertEqual(disposition.state, .published)
    }
}
