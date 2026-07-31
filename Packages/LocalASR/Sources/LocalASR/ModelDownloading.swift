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
public final class URLSessionModelDownloader: NSObject, ModelDownloading, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // Загрузка идёт по явной команде пользователя, ждать «удобного момента»
            // не надо. При этом на дорогой сети не начинаем без спроса.
            configuration.waitsForConnectivity = true
            configuration.allowsExpensiveNetworkAccess = false
            configuration.allowsConstrainedNetworkAccess = false
            configuration.timeoutIntervalForResource = 3600
            self.session = URLSession(configuration: configuration)
        }
        super.init()
    }

    public func download(
        from url: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        do {
            let (bytes, response) = try await session.bytes(from: url)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ModelDownloadError.httpStatus(http.statusCode)
            }

            let temporary = FileManager.default.temporaryDirectory
                .appending(path: "wai-model-\(UUID().uuidString)", directoryHint: .notDirectory)
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(1024 * 1024)
            var received: Int64 = 0

            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1024 * 1024 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress(received)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                onProgress(received)
            }

            return temporary
        } catch let error as ModelDownloadError {
            throw error
        } catch is CancellationError {
            throw ModelDownloadError.cancelled
        } catch {
            throw ModelDownloadError.network(error.localizedDescription)
        }
    }
}
