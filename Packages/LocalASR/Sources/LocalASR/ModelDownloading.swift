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
    case cancelled
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

    public init(configuration: URLSessionConfiguration? = nil) {
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
        // Делегат ставится на сессию, а не на задачу. Разница не косметическая:
        // задаче система отдаёт лишь округлённую долю (замер — два обновления
        // с числом «100» на файл), а сессии — настоящие байты (89 обновлений на
        // тех же 23 МБ). Индикатор без этого замирает на самом большом файле,
        // а он — 92% всей установки.
        let observer = DownloadObserver(onProgress: onProgress)
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
    private let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
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
        onProgress(totalBytesWritten)
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
