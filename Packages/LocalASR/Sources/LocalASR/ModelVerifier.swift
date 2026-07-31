import CryptoKit
import Foundation

/// Проверка скачанных файлов по манифесту.
///
/// Считает суммы потоково: файл энкодера весит 446 МБ, и загонять его в память
/// целиком незачем.
public struct ModelVerifier: Sendable {
    /// Размер куска при чтении. Компромисс между числом системных вызовов и памятью.
    private static let chunkSize = 4 * 1024 * 1024

    public init() {}

    public enum Failure: Error, Sendable, Equatable {
        case fileMissing(String)
        case sizeMismatch(path: String, expected: Int64, actual: Int64)
        case checksumMismatch(String)
        case unreadable(path: String, reason: String)
    }

    /// Проверить один файл: сначала размер (дёшево), потом сумму.
    public func verify(file: ModelManifest.File, at url: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            throw Failure.fileMissing(file.path)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: url.path)
        } catch {
            throw Failure.unreadable(path: file.path, reason: error.localizedDescription)
        }

        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == file.byteCount else {
            throw Failure.sizeMismatch(path: file.path, expected: file.byteCount, actual: actualSize)
        }

        let digest = try sha256(of: url, path: file.path)
        guard digest == file.sha256.lowercased() else {
            throw Failure.checksumMismatch(file.path)
        }
    }

    /// Проверить весь набор. Прерывается на первой же проблеме: смысла продолжать
    /// нет, установка всё равно не состоится.
    public func verifyAll(
        manifest: ModelManifest,
        inside directory: URL,
        layout: ModelInstallLayout,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        for (index, file) in manifest.files.enumerated() {
            let destination = try layout.destination(for: file, inside: directory)
            try verify(file: file, at: destination)
            progress?(index + 1, manifest.files.count)
        }
    }

    /// Потоковый SHA-256.
    public func sha256(of url: URL, path: String) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.unreadable(path: path, reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: Self.chunkSize)
            } catch {
                throw Failure.unreadable(path: path, reason: error.localizedDescription)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
