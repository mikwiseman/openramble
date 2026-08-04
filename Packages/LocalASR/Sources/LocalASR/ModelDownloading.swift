import Foundation

/// Загрузка одного файла.
///
/// Вынесено в протокол ради тестов: настоящая сеть в них не участвует, а вся
/// логика установки — состояния, проверки, атомарный переезд — проверяется на
/// подставном загрузчике.
public protocol ModelDownloading: Sendable {
    /// Скачать файл по адресу во временное место и вернуть путь к нему.
    ///
    /// - Parameter onProgress: сколько байт этого файла уже получено.
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

/// Чистая политика сетевой поверхности model download.
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

/// Загрузчик поверх URLSession.
///
/// Единственное место в проекте — вместе с обёрткой Sparkle — где вообще
/// допустим сетевой вызов. Это проверяется в CI.
///
/// Файл пишет на диск сама система, большими кусками и не держа его в памяти.
/// Раньше здесь был цикл по одному байту: на энкодере модели это 445 миллионов
/// проходов асинхронного цикла, и загрузка упиралась не в сеть, а в него.
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
            // Загрузка идёт по явной команде пользователя, ждать «удобного момента»
            // не надо. При этом на дорогой сети не начинаем без спроса.
            configuration.waitsForConnectivity = true
            configuration.allowsExpensiveNetworkAccess = false
            configuration.allowsConstrainedNetworkAccess = false
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
        // Делегат ставится на сессию, а не на задачу. Разница не косметическая:
        // задаче система отдаёт лишь округлённую долю (замер — два обновления
        // с числом «100» на файл), а сессии — настоящие байты (89 обновлений на
        // тех же 23 МБ). Индикатор без этого замирает на самом большом файле,
        // а он — 92% всей установки.
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

/// Приёмник событий одной загрузки.
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

    /// Отдать результат ровно один раз.
    ///
    /// Событий приходит два — «файл скачан» и «задача завершилась», — и на
    /// успешной загрузке они оба успешные. Возобновить ожидание дважды значит
    /// уронить процесс.
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
            finish(.failure(ModelDownloadError.unapprovedURL(request.url?.host() ?? "неизвестный адрес")))
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
        // Ответ с ошибкой тоже приезжает файлом — со страницей ошибки внутри.
        // Без проверки статуса она уехала бы в установку и провалила бы уже
        // сверку контрольных сумм, но с невнятной причиной.
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

        // Система удаляет файл, как только этот метод вернёт управление, —
        // переносим здесь же.
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
            // Успех уже отдан выше; сюда попадаем только если файла так и не
            // случилось — молча повиснуть на этом нельзя.
            finish(.failure(ModelDownloadError.network("загрузка завершилась без файла")))
            return
        }

        if (error as? URLError)?.code == .cancelled {
            finish(.failure(ModelDownloadError.cancelled))
        } else {
            finish(.failure(ModelDownloadError.network(error.localizedDescription)))
        }
    }
}
