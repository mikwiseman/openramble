import LocalASR
import UIKit
import XCTest
@testable import OpenRamble

final class ModelDownloadTests: XCTestCase {
    private let policy = ModelDownloadPolicy()
    private let github = URL(string: "https://release-assets.githubusercontent.com/model")!

    func testAWholeFileFromAnApprovedHostPasses() {
        XCTAssertNil(BackgroundModelDownloader.check(
            status: 200, finalURL: github, expectedBytes: 10, actualBytes: 10, policy: policy))
    }

    func testAnErrorPageIsNotAModel() {
        XCTAssertEqual(BackgroundModelDownloader.check(
            status: 404, finalURL: github, expectedBytes: 10, actualBytes: 10, policy: policy), .httpStatus(404))
    }

    func testARedirectOffTheAllowlistIsRefused() {
        // A background transfer follows redirects itself; the host it ended on is checked.
        let elsewhere = URL(string: "https://example.com/model")!
        XCTAssertEqual(BackgroundModelDownloader.check(
            status: 200, finalURL: elsewhere, expectedBytes: 10, actualBytes: 10, policy: policy),
            .unapprovedURL("example.com"))
    }

    func testAFileOfTheWrongSizeIsRefused() {
        XCTAssertEqual(BackgroundModelDownloader.check(
            status: 200, finalURL: github, expectedBytes: 10, actualBytes: 9, policy: policy),
            .unexpectedSize(expected: 10, actual: 9))
    }

    func testAFullDiskIsNotANetworkProblem() {
        XCTAssertTrue(BackgroundModelDownloader.isLocalWriteFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertFalse(BackgroundModelDownloader.isLocalWriteFailure(URLError(.networkConnectionLost)))
    }
}

final class ModelSetupTests: XCTestCase {
    @MainActor
    func testStoreStatesReadAsThePersonSeesThem() {
        XCTAssertEqual(ModelSetup.phase(for: .notInstalled), .absent)
        XCTAssertEqual(ModelSetup.phase(for: .repairRequired("x")), .absent, "an interrupted install is fixed by downloading again")
        XCTAssertEqual(ModelSetup.phase(for: .failed(.cancelled)), .absent, "cancelling is not a failure")
        XCTAssertEqual(ModelSetup.phase(for: .downloading(receivedBytes: 1, totalBytes: 2)), .downloading(received: 1, total: 2))
        guard case .failed(let message) = ModelSetup.phase(for: .failed(.notEnoughDiskSpace(requiredBytes: 2_000_000_000, availableBytes: 1_000_000_000))) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(message.contains("free space"), message)
    }

    @MainActor
    func testTheAppShipsTheManifestTheMacShips() throws {
        let manifest = try ModelManifest.bundled()
        XCTAssertEqual(manifest.quantization, "Q4_K_M")
        XCTAssertEqual(manifest.files.map(\.path), ["parakeet-ultra-Q4_K_M.gguf"])
        XCTAssertEqual(ModelSetup.standard().byteCount, 486_280_096)
    }
}

@MainActor
final class ClipboardTests: XCTestCase {
    func testWordsGoToTheClipboard() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        Clipboard.copy("Hello there.", to: pasteboard)
        XCTAssertEqual(pasteboard.string, "Hello there.")
    }
}

final class LayoutTests: XCTestCase {
    func testTakesAreGroupedByDayInOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = Date(timeIntervalSince1970: 1_700_000_000)
        let takes = [
            Take(recordedAt: monday, duration: 1),
            Take(recordedAt: monday.addingTimeInterval(60), duration: 1),
            Take(recordedAt: monday.addingTimeInterval(86_400), duration: 1),
        ]
        let days = TakeList.days(takes, calendar: calendar)
        XCTAssertEqual(days.map(\.takes.count), [2, 1])
    }

    func testDurationsReadLikeAClock() {
        XCTAssertEqual(Take.clock(7), "0:07")
        XCTAssertEqual(Take.clock(754), "12:34")
        XCTAssertEqual(Take.clock(3_723), "1:02:03")
    }

    func testLevelsFillTheRangeOfSpeech() {
        XCTAssertEqual(MicrophoneRecorder.normalized(decibels: -160), 0)
        XCTAssertEqual(MicrophoneRecorder.normalized(decibels: 0), 1)
        XCTAssertEqual(MicrophoneRecorder.normalized(decibels: -25), 0.5, accuracy: 0.001)
        XCTAssertEqual(MicrophoneRecorder.normalized(decibels: -.infinity), 0)
    }
}

/// Records what the store asked for and refuses, so nothing is fetched.
final class RecordingDownloader: ModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var requested: [URL] { lock.withLock { urls } }

    func download(from url: URL, expectedBytes: Int64, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        lock.withLock { urls.append(url) }
        throw ModelDownloadError.cancelled
    }
}

final class ModelResumeTests: XCTestCase {
    private func setup(pending: Bool) throws -> (ModelSetup, RecordingDownloader, URL) {
        let root = URL.temporaryDirectory.appending(path: "models-\(UUID().uuidString)", directoryHint: .isDirectory)
        let manifest = ModelManifest(
            modelID: "test-model", repository: "handy-computer/test-model", revision: "abc",
            runtimeVersion: "test", quantization: "Q4_K_M", license: "MIT",
            files: [.init(path: "model.gguf", byteCount: 10, sha256: String(repeating: "0", count: 64))]
        )
        let downloader = RecordingDownloader()
        let store = ModelStore(
            manifest: manifest, layout: try ModelInstallLayout(manifest: manifest, root: root),
            downloader: downloader, retryDelay: .zero
        )
        return (MainActor.assumeIsolated {
            ModelSetup(store: store, byteCount: 10, pendingDownload: { pending })
        }, downloader, root)
    }

    @MainActor
    func testADownloadStartedBeforeTheAppEndedIsCarriedOn() async throws {
        let (setup, downloader, root) = try setup(pending: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setup.start { _ in }
        for _ in 0..<100 where downloader.requested.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(downloader.requested.isEmpty, "the install the person started goes on by itself")
    }

    @MainActor
    func testNothingIsDownloadedUnasked() async throws {
        let (setup, downloader, root) = try setup(pending: false)
        defer { try? FileManager.default.removeItem(at: root) }
        setup.start { _ in }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(downloader.requested.isEmpty, "the model is fetched only when the person asks")
        XCTAssertEqual(setup.phase, .absent)
    }
}
