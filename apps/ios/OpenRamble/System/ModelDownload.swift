import Foundation
import LocalASR
import UIKit

/// The iPhone app's one network area: the voice model, downloaded once, when
/// the person taps Download after reading its size.
///
/// `scripts/check-network-surface.sh` allows the network in this file and no
/// other file of the iPhone app. It fetches only the addresses in the model
/// manifest (GitHub, then Hugging Face), only over HTTPS, and only hosts that
/// `ModelDownloadPolicy` approves; `ModelStore` then checks every byte against
/// the manifest's SHA-256 before the model is used.
///
/// It is a background transfer, unlike the Mac's: a 486 MB file takes a minute
/// or more on a phone, and the person should be free to leave the app while it
/// arrives. The system carries on with the transfer while the app is suspended.
/// If the system ends the app meanwhile, a file that finishes while nobody is
/// waiting is kept, and the next attempt picks it up instead of starting over.
final class BackgroundModelDownloader: NSObject, ModelDownloading, @unchecked Sendable {
    static let sessionIdentifier = "is.waiwai.dictation.model-download"
    static let shared = BackgroundModelDownloader()

    private let policy = ModelDownloadPolicy()
    private let lock = NSLock()
    private var waiting: [Int: Waiting] = [:]
    private var finishEvents: (@Sendable () -> Void)?
    private var resumeAttempts: [Int: Int] = [:]

    private struct Waiting {
        let url: URL
        let expectedBytes: Int64
        let onProgress: @Sendable (Int64) -> Void
        let continuation: CheckedContinuation<URL, any Error>
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // The person asked for it and is watching: start now, on whatever
        // network there is, including cellular and Low Data Mode.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Where a file that finished with nobody waiting is kept until asked for.
    private var arrivedFolder: URL {
        URL.cachesDirectory.appending(path: "model-arrived", directoryHint: .isDirectory)
    }

    private func arrivedFile(for url: URL) -> URL {
        arrivedFolder.appending(path: url.lastPathComponent)
    }

    /// Reconnects to the system's transfer when the app launches, so a
    /// download that went on, or finished, while the app was not running is
    /// handed over. True when there is one: the person had started a download
    /// that has not been installed yet.
    func reconnect() async -> Bool {
        let tasks = await session.allTasks
        if !tasks.isEmpty { return true }
        return FileManager.default.fileExists(atPath: arrivedFolder.path)
            && ((try? FileManager.default.contentsOfDirectory(atPath: arrivedFolder.path))?.isEmpty == false)
    }

    /// Called by the app delegate when the system wakes the app for this
    /// session's events.
    func handleEvents(completion: @escaping @Sendable () -> Void) {
        lock.withLock { finishEvents = completion }
        _ = session
    }

    // MARK: - ModelDownloading

    func download(
        from url: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        try policy.validate(url)
        guard expectedBytes > 0 else {
            throw ModelDownloadError.unexpectedSize(expected: expectedBytes, actual: 0)
        }

        // A file that finished while the app was not running.
        let arrived = arrivedFile(for: url)
        if let size = Self.fileSize(arrived) {
            if size == expectedBytes {
                let handed = FileManager.default.temporaryDirectory.appending(path: "model-\(UUID().uuidString)")
                try? FileManager.default.moveItem(at: arrived, to: handed)
                if Self.fileSize(handed) == expectedBytes { return handed }
            }
            try? FileManager.default.removeItem(at: arrived)
        }

        // A transfer the system kept going while the app was away. One that
        // finished meanwhile is handed over by the delegate a moment after
        // the session reconnects; wait for that rather than start again.
        let tasks = await session.allTasks.compactMap { $0 as? URLSessionDownloadTask }
            .filter { $0.originalRequest?.url == url }
        if tasks.contains(where: { $0.state == .completed }) {
            for _ in 0..<50 where Self.fileSize(arrived) == nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            if Self.fileSize(arrived) == expectedBytes {
                let handed = FileManager.default.temporaryDirectory.appending(path: "model-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: arrived, to: handed)
                return handed
            }
        }
        let running = tasks.first { $0.state == .running || $0.state == .suspended }
        let task = running ?? session.downloadTask(with: url)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    waiting[task.taskIdentifier] = Waiting(
                        url: url, expectedBytes: expectedBytes, onProgress: onProgress, continuation: continuation
                    )
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Decisions, kept pure so they can be tested

    /// Whether a finished transfer is the file the manifest describes, as far
    /// as can be told before the checksum.
    static func check(
        status: Int?, finalURL: URL?, expectedBytes: Int64, actualBytes: Int64?, policy: ModelDownloadPolicy
    ) -> ModelDownloadError? {
        if let status, !(200...299).contains(status) { return .httpStatus(status) }
        // A background transfer follows redirects on its own, so the host it
        // ended on is checked here instead of at each hop.
        if let finalURL, !policy.allows(finalURL) { return .unapprovedURL(finalURL.host() ?? "unknown address") }
        guard let actualBytes else { return .network("the download finished without a file") }
        guard actualBytes == expectedBytes else { return .unexpectedSize(expected: expectedBytes, actual: actualBytes) }
        return nil
    }

    static func isLocalWriteFailure(_ error: any Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSURLErrorDomain:
            return [NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile, NSURLErrorCannotMoveFile].contains(error.code)
        case NSCocoaErrorDomain:
            return [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError].contains(error.code)
        case NSPOSIXErrorDomain:
            return error.code == Int(ENOSPC) || error.code == Int(EDQUOT)
        default:
            return false
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private func take(_ task: URLSessionTask) -> Waiting? {
        lock.withLock { waiting.removeValue(forKey: task.taskIdentifier) }
    }
}

extension BackgroundModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let entry = lock.withLock { waiting[downloadTask.taskIdentifier] }
        guard let entry else { return }
        guard totalBytesWritten <= entry.expectedBytes else {
            downloadTask.cancel()
            take(downloadTask)?.continuation.resume(throwing: ModelDownloadError.unexpectedSize(
                expected: entry.expectedBytes, actual: totalBytesWritten
            ))
            return
        }
        entry.onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let entry = take(downloadTask)
        let expected = entry?.expectedBytes ?? downloadTask.countOfBytesExpectedToReceive
        let problem = Self.check(
            status: (downloadTask.response as? HTTPURLResponse)?.statusCode,
            finalURL: downloadTask.currentRequest?.url,
            expectedBytes: expected,
            actualBytes: Self.fileSize(location),
            policy: policy
        )
        // The system deletes the file when this method returns: move it now.
        guard let entry else {
            // Nobody is waiting: the app was ended while the file arrived.
            guard problem == nil, let url = downloadTask.originalRequest?.url else { return }
            try? FileManager.default.createDirectory(at: arrivedFolder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: arrivedFile(for: url))
            try? FileManager.default.moveItem(at: location, to: arrivedFile(for: url))
            return
        }
        if let problem {
            entry.continuation.resume(throwing: problem)
            return
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "model-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            entry.continuation.resume(returning: destination)
        } catch {
            entry.continuation.resume(throwing: ModelDownloadError.localWriteFailed(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }  // success was handled when the file arrived
        guard let entry = take(task) else { return }
        if (error as? URLError)?.code == .cancelled {
            entry.continuation.resume(throwing: ModelDownloadError.cancelled)
            return
        }
        if Self.isLocalWriteFailure(error) {
            entry.continuation.resume(throwing: ModelDownloadError.localWriteFailed(error.localizedDescription))
            return
        }
        // A dropped transfer continues from the bytes it already has, up to
        // three times; after that ModelStore decides whether to try the mirror.
        let attempts = lock.withLock { resumeAttempts[task.taskIdentifier, default: 0] }
        if attempts < 3, let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let next = session.downloadTask(withResumeData: data)
            lock.withLock {
                resumeAttempts[next.taskIdentifier] = attempts + 1
                waiting[next.taskIdentifier] = entry
            }
            next.resume()
            return
        }
        entry.continuation.resume(throwing: ModelDownloadError.network(error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { finishEvents = nil }
            return finishEvents
        }
        if let completion {
            DispatchQueue.main.async { completion() }
        }
    }
}

extension AppDelegate {
    /// The system woke the app because the model download needs it.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundModelDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        nonisolated(unsafe) let completion = completionHandler
        BackgroundModelDownloader.shared.handleEvents { completion() }
    }
}
