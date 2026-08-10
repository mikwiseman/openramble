import Foundation

/// Upload one file.
///
/// Logged for the sake of tests: the real network does not participate in them, but the entire
/// installation logic - states, checks, atomic move - is checked for
/// dummy bootloader.
public protocol ModelDownloading: Sendable {
    /// Download the file at the address to a temporary location and return the path to it.
    ///
    /// - Parameter onProgress: how many bytes of this file have already been received.
    func download(
        from url: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL
}

public enum ModelDownloadError: Error, Sendable, Equatable {
    case network(String)
    case httpStatus(Int)
    case unapprovedURL(String)
    case unexpectedSize(expected: Int64, actual: Int64)
    case cancelled
}

/// Clean network surface policy model download.
public struct ModelDownloadPolicy: Sendable {
    public init() {}

    public func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else {
            return false
        }
        return host == "huggingface.co"
            || host.hasSuffix(".huggingface.co")
            || host == "hf.co"
            || host.hasSuffix(".hf.co")
            || host == "github.com"
            || host == "objects.githubusercontent.com"
            || host == "release-assets.githubusercontent.com"
    }

    public func validate(_ url: URL) throws {
        guard allows(url) else {
            throw ModelDownloadError.unapprovedURL(url.host() ?? url.absoluteString)
        }
    }
}

/// Loader on top of URLSession.
///
/// The only place in the project - together with the Sparkle wrapper - where at all
/// allow network call. This is checked in CI.
///
/// The file is written to disk by the system itself, in large chunks and without keeping it in memory.
/// Previously, there was a cycle of one byte: on the model encoder this is 445 million
/// passes of the asynchronous loop, and the loading rested not on the network, but on it.
public final class URLSessionModelDownloader: NSObject, ModelDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let policy: ModelDownloadPolicy

    public init(
        configuration: URLSessionConfiguration? = nil,
        policy: ModelDownloadPolicy = ModelDownloadPolicy()
    ) {
        self.policy = policy
        if let configuration {
            self.configuration = configuration
        } else {
            let configuration = URLSessionConfiguration.default
            // The user explicitly starts this large download after seeing its size.
            // Waiting for a different network leaves onboarding stuck at zero bytes and
            // also prevents the GitHub fallback from being tried. Start on the current
            // network, including hotspots and Low Data Mode, or fail so the UI can retry.
            configuration.waitsForConnectivity = false
            configuration.allowsExpensiveNetworkAccess = true
            configuration.allowsConstrainedNetworkAccess = true
            configuration.timeoutIntervalForResource = 3600
            self.configuration = configuration
        }
        super.init()
    }

    public func download(
        from url: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        try policy.validate(url)
        guard expectedBytes > 0 else {
            throw ModelDownloadError.unexpectedSize(expected: expectedBytes, actual: 0)
        }
        // The delegate is assigned to the session, not to the task. The difference is not cosmetic:
        // the system gives only a rounded share to the task (measured - two updates
        // with the number "100" per file), and sessions are real bytes (89 updates per
        // the same 23 MB). Without this, the indicator freezes on the largest file,
        // and he is 92% of the entire installation.
        let observer = DownloadObserver(
            expectedBytes: expectedBytes,
            policy: policy,
            onProgress: onProgress
        )
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                observer.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Receiver of single boot events.
private final class DownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let policy: ModelDownloadPolicy
    private let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    init(
        expectedBytes: Int64,
        policy: ModelDownloadPolicy,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) {
        self.expectedBytes = expectedBytes
        self.policy = policy
        self.onProgress = onProgress
    }

    func attach(_ continuation: CheckedContinuation<URL, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    /// Return the result exactly once.
    ///
    /// There are two events - “file downloaded” and “task completed” - and on
    /// successful loading, they are both successful. Resuming the wait twice means
    /// drop the process.
    private func finish(_ result: Result<URL, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= expectedBytes else {
            downloadTask.cancel()
            finish(.failure(ModelDownloadError.unexpectedSize(expected: expectedBytes, actual: totalBytesWritten)))
            return
        }
        onProgress(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, policy.allows(url) else {
            finish(.failure(ModelDownloadError.unapprovedURL(request.url?.host() ?? "unknown address")))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The response with an error also arrives as a file - with an error page inside.
        // Without checking the status, it would have gone to the installation and would have failed already
        // checking checksums, but with an unclear reason.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            finish(.failure(ModelDownloadError.httpStatus(http.statusCode)))
            return
        }
        if let expected = downloadTask.response?.expectedContentLength,
           expected >= 0,
           expected != expectedBytes {
            finish(.failure(ModelDownloadError.unexpectedSize(expected: expectedBytes, actual: expected)))
            return
        }

        let actual: Int64
        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            actual = Int64(values.fileSize ?? -1)
        } catch {
            finish(.failure(ModelDownloadError.network(error.localizedDescription)))
            return
        }
        guard actual == expectedBytes else {
            finish(.failure(ModelDownloadError.unexpectedSize(expected: expectedBytes, actual: actual)))
            return
        }

        // The system deletes the file as soon as this method returns control -
        // move it here.
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "wai-model-\(UUID().uuidString)", directoryHint: .notDirectory)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(ModelDownloadError.network(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else {
            // Success has already been given higher; We get here only if there is no file
            // it happened - you can’t hang on to it in silence.
            finish(.failure(ModelDownloadError.network("the download finished without a file")))
            return
        }

        if (error as? URLError)?.code == .cancelled {
            finish(.failure(ModelDownloadError.cancelled))
        } else {
            finish(.failure(ModelDownloadError.network(error.localizedDescription)))
        }
    }
}
