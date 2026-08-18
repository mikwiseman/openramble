import CryptoKit
import XCTest
@testable import LocalASR

/// Retrying a flaky transfer.
///
/// The install is 586 MB across many files, and the encoder alone is 92% of it.
/// A single dropped TLS handshake anywhere in that stream used to fail the whole
/// installation and leave onboarding on "Model installation failed" — the user
/// had done nothing wrong and had nothing to fix. Reported from a real machine
/// behind a VPN, where both mirrors blinked within the same attempt.
///
/// The rule that matters most here is what is NOT retried. A retry that hammers
/// a disallowed host, ignores a cancel, or re-downloads half a gigabyte against
/// a 404 is worse than the original failure.
final class ModelDownloadRetryTests: XCTestCase {
    private var root: URL!

    private let fileA = Data("first file".utf8)
    private let fileB = Data("second file".utf8)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var contents: [String: Data] {
        ["Encoder.mlmodelc/weight.bin": fileA, "vocab.json": fileB]
    }

    /// Both manifest files are attempted, so a per-file expectation is the
    /// honest way to say "one attempt, no retry".
    private var manifestFileCount: Int { makeManifest().files.count }

    private func makeManifest() -> ModelManifest {
        ModelManifest(
            modelID: "test-model",
            repository: "acme/test",
            revision: String(repeating: "a", count: 40),
            runtimeVersion: "0.15.5",
            quantization: "test",
            license: "CC-BY-4.0",
            files: [
                .init(path: "Encoder.mlmodelc/weight.bin", byteCount: Int64(fileA.count), sha256: sha256(fileA)),
                .init(path: "vocab.json", byteCount: Int64(fileB.count), sha256: sha256(fileB)),
            ],
            mirror: .init(repository: "mikwiseman/openramble", releaseTag: "models-test")
        )
    }

    /// Retries are instant in tests. The production delay is real, and waiting
    /// it out here would trade seconds of test time for nothing.
    private func makeStore(_ downloader: ModelDownloading) -> ModelStore {
        let manifest = makeManifest()
        return ModelStore(
            manifest: manifest,
            layout: ModelInstallLayout(
                root: root,
                modelID: manifest.modelID,
                revision: manifest.revision,
                engineFolderName: "repo"
            ),
            downloader: downloader,
            retryDelay: .zero
        )
    }

    // MARK: - What is retried

    /// The reported failure: the leading source blinks, then works.
    func testTransientNetworkFailureIsRetriedOnTheSameSource() async throws {
        let downloader = FakeDownloader(contents: contents)
        await downloader.setTransientFailures(1, forHost: "github.com")

        let store = makeStore(downloader)
        await store.install()

        let state = await store.currentState()
        guard case .ready = state else { return XCTFail("expected a finished install, got \(state)") }
        let hosts = await downloader.requestedHosts
        XCTAssertFalse(
            hosts.contains("huggingface.co"),
            "a blink must not cost us the faster source"
        )
    }

    /// The exact pair of errors from the screenshot: both mirrors blink inside
    /// one attempt. Before the retry this was a dead end.
    func testBothMirrorsBlinkingStillInstalls() async throws {
        let downloader = FakeDownloader(contents: contents)
        await downloader.setTransientFailures(
            1, error: .network("Could not connect to the server."), forHost: "github.com"
        )
        await downloader.setTransientFailures(
            1, error: .network("A TLS error caused the secure connection to fail."), forHost: "github.com"
        )

        let store = makeStore(downloader)
        await store.install()

        let state = await store.currentState()
        guard case .ready = state else { return XCTFail("expected a finished install, got \(state)") }
    }

    /// A server-side 5xx is the server's bad minute, not our bad address.
    func testServerErrorIsRetried() async throws {
        let downloader = FakeDownloader(contents: contents)
        await downloader.setTransientFailures(1, error: .httpStatus(503), forHost: "github.com")

        let store = makeStore(downloader)
        await store.install()

        let state = await store.currentState()
        guard case .ready = state else { return XCTFail("expected a finished install, got \(state)") }
    }

    /// Retrying is bounded. An endlessly flaky source must hand over to the
    /// mirror rather than spin on half a gigabyte forever.
    func testRetriesAreBoundedAndThenTheOtherSourceIsUsed() async throws {
        let downloader = FakeDownloader(contents: contents)
        await downloader.setFailure(.network("down"), forHost: "github.com")

        await makeStore(downloader).install()

        let attempts = await downloader.attemptsByHost
        XCTAssertNotNil(attempts["huggingface.co"], "the other source must be reached")
        let flaky = attempts["github.com"] ?? 0
        XCTAssertGreaterThan(flaky, 2, "a flaky source deserves more than one try")
        XCTAssertLessThanOrEqual(flaky, 8, "but not an unbounded number of them")
    }

    // MARK: - What is never retried

    /// Cancel means cancel. Retrying after it would keep pulling 586 MB against
    /// a direct command.
    func testCancellationIsNeverRetried() async throws {
        let downloader = FakeDownloader(contents: contents)
        await downloader.setFailure(.cancelled)

        let store = makeStore(downloader)
        await store.install()

        let state = await store.currentState()
        XCTAssertEqual(state, .notInstalled, "cancel is a cancel, not a failed install")
        let attempts = await downloader.attemptsByHost
        XCTAssertEqual(attempts.values.reduce(0, +), 1, "exactly one attempt, then stop")
    }

    /// A redirect off the allowlist is a policy violation, not a bad minute.
    /// Retrying it would knock on a disallowed host repeatedly.
    func testDisallowedHostIsNeverRetried() async throws {
        let downloader = FakeDownloader(contents: contents)
        await downloader.setFailure(.unapprovedURL("evil.example.com"), forHost: "github.com")

        await makeStore(downloader).install()

        let attempts = await downloader.attemptsByHost
        XCTAssertEqual(
            attempts["github.com"],
            manifestFileCount,
            "policy failures get exactly one attempt per file, never a retry"
        )
    }

    /// 404 is a wrong address. No number of retries turns it into a right one.
    func testNotFoundIsNeverRetried() async throws {
        let downloader = FakeDownloader(contents: contents)
        await downloader.setFailure(.httpStatus(404), forHost: "github.com")

        await makeStore(downloader).install()

        let attempts = await downloader.attemptsByHost
        XCTAssertEqual(attempts["github.com"], manifestFileCount)
    }

    /// A size mismatch means the source holds a different file. Re-pulling half
    /// a gigabyte cannot change what is on the other end.
    func testSizeMismatchIsNeverRetried() async throws {
        let downloader = FakeDownloader(contents: contents)
        await downloader.setFailure(.unexpectedSize(expected: 10, actual: 20), forHost: "github.com")

        await makeStore(downloader).install()

        let attempts = await downloader.attemptsByHost
        XCTAssertEqual(attempts["github.com"], manifestFileCount)
    }

    /// Both sources genuinely gone: the message still names both, as before.
    func testPermanentFailureOfBothSourcesNamesBoth() async throws {
        let downloader = FakeDownloader(contents: [:])
        await downloader.setFailure(.httpStatus(404))

        let store = makeStore(downloader)
        await store.install()

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .download(message) = error else {
            return XCTFail("expected a clear download failure, got \(state)")
        }
        XCTAssertTrue(message.contains("huggingface.co"))
        XCTAssertTrue(message.contains("github.com"))
    }
}

/// A full disk is this Mac's problem, and retrying makes it worse.
final class LocalWriteFailureTests: XCTestCase {
    private var root: URL!
    private let fileA = Data("first file".utf8)
    private let fileB = Data("second file".utf8)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "disk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeStore(_ downloader: ModelDownloading) -> ModelStore {
        let manifest = ModelManifest(
            modelID: "test-model",
            repository: "acme/test",
            revision: String(repeating: "a", count: 40),
            runtimeVersion: "0.15.5",
            quantization: "test",
            license: "CC-BY-4.0",
            files: [
                .init(path: "Encoder.mlmodelc/weight.bin", byteCount: Int64(fileA.count), sha256: sha256(fileA)),
                .init(path: "vocab.json", byteCount: Int64(fileB.count), sha256: sha256(fileB)),
            ],
            mirror: .init(repository: "mikwiseman/openramble", releaseTag: "models-test")
        )
        return ModelStore(
            manifest: manifest,
            layout: ModelInstallLayout(
                root: root, modelID: manifest.modelID,
                revision: manifest.revision, engineFolderName: "repo"
            ),
            downloader: downloader,
            retryDelay: .zero
        )
    }

    /// One attempt, not six. Before this, a disk that filled partway through the
    /// 425 MB encoder pulled it six times — roughly 2.7 GB — and still failed.
    func testFullDiskIsNotRetried() async {
        let downloader = FakeDownloader(contents: [:])
        await downloader.setFailure(
            .localWriteFailed("The file couldn't be saved because there isn't enough space.")
        )

        await makeStore(downloader).install()

        let attempts = await downloader.attemptsByHost
        XCTAssertEqual(
            attempts.values.reduce(0, +), 1,
            "a full disk gets one attempt: retrying refills the disk, and the "
                + "mirror would download the same bytes into the same full disk"
        )
    }

    /// The reason reaches the user instead of being reported as a network fault.
    func testFullDiskSaysSoInsteadOfBlamingTheNetwork() async {
        let downloader = FakeDownloader(contents: [:])
        await downloader.setFailure(.localWriteFailed("there isn't enough space"))

        let store = makeStore(downloader)
        await store.install()

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .download(message) = error else {
            return XCTFail("expected a clear failure, got \(state)")
        }
        XCTAssertTrue(message.contains("enough space"), "the real reason must survive: \(message)")
    }

    /// The classifier must not mistake a dropped connection for a full disk —
    /// that would stop retrying the case retries exist for.
    func testNetworkErrorsAreNotMistakenForDiskErrors() {
        XCTAssertTrue(URLSessionModelDownloader.isLocalWriteFailure(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        ))
        XCTAssertTrue(URLSessionModelDownloader.isLocalWriteFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile)
        ))
        XCTAssertTrue(URLSessionModelDownloader.isLocalWriteFailure(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        ))
        XCTAssertFalse(URLSessionModelDownloader.isLocalWriteFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        ))
        XCTAssertFalse(URLSessionModelDownloader.isLocalWriteFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        ))
        XCTAssertFalse(URLSessionModelDownloader.isLocalWriteFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        ))
    }
}

/// Corrupt content is what the mirror is for.
final class CorruptContentFallbackTests: XCTestCase {
    private var root: URL!
    private let good = Data("the real bytes".utf8)
    private let other = Data("wrong contents".utf8)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "corrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeStore(_ downloader: ModelDownloading) -> ModelStore {
        let manifest = ModelManifest(
            modelID: "test-model",
            repository: "acme/test",
            revision: String(repeating: "a", count: 40),
            runtimeVersion: "0.15.5",
            quantization: "test",
            license: "CC-BY-4.0",
            files: [.init(path: "vocab.json", byteCount: Int64(good.count), sha256: sha256(good))],
            mirror: .init(repository: "mikwiseman/openramble", releaseTag: "models-test")
        )
        return ModelStore(
            manifest: manifest,
            layout: ModelInstallLayout(
                root: root, modelID: manifest.modelID,
                revision: manifest.revision, engineFolderName: "repo"
            ),
            downloader: downloader,
            retryDelay: .zero
        )
    }

    /// The primary serves the right number of wrong bytes; the mirror is clean.
    ///
    /// Before this, verification ran only as a final pass, so the install died
    /// with a checksum error, deleted everything, and sent the user back to the
    /// same bad source on retry. The manifest promises the mirror exists so a
    /// single source is not a single point of failure.
    func testCorruptPrimaryFallsBackToTheMirror() async throws {
        // Same length, different bytes: the size check cannot catch this.
        XCTAssertEqual(good.count, other.count, "the fixture must defeat the size check")

        let downloader = FakeDownloader(contents: ["vocab.json": good])
        await downloader.setContents(["vocab.json": other], forHost: "github.com")

        let store = makeStore(downloader)
        await store.install()

        let state = await store.currentState()
        guard case .ready = state else { return XCTFail("the mirror should have saved it, got \(state)") }

        let hosts = await downloader.requestedHosts
        XCTAssertTrue(hosts.contains("github.com"), "the mirror must be tried")
    }

    /// Corrupt on both sides still fails, and says why.
    func testCorruptOnBothSourcesFailsClearly() async throws {
        let downloader = FakeDownloader(contents: ["vocab.json": other])

        let store = makeStore(downloader)
        await store.install()

        let state = await store.currentState()
        guard case .failed = state else { return XCTFail("expected a failure, got \(state)") }
    }

    /// Re-serving the same corrupt bytes is pointless, so it is not retried.
    func testCorruptContentIsNotRetriedOnTheSameSource() async throws {
        let downloader = FakeDownloader(contents: ["vocab.json": other])

        await makeStore(downloader).install()

        let attempts = await downloader.attemptsByHost
        XCTAssertEqual(attempts["huggingface.co"], 1, "the same source will serve the same bytes")
        XCTAssertEqual(attempts["github.com"], 1)
    }
}
