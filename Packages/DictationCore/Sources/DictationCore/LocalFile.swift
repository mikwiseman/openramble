import Foundation

/// Чтение файла с диска.
///
/// Существует, чтобы в проекте не встречался `Data(contentsOf:)`. Тот принимает
/// любой URL и по http-адресу молча уйдёт в сеть — а значит, автоматическая
/// проверка сетевой поверхности не смогла бы отличить чтение настроек от
/// незаявленной отправки данных. Здесь адрес обязан быть файловым.
public enum LocalFile {
    public enum Failure: Error, Sendable, Equatable {
        case notAFileURL(String)
        case unreadable(String)
    }

    /// Прочитать локальный файл целиком.
    public static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else {
            throw Failure.notAFileURL(url.scheme ?? "no scheme")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
    }
}
