import Foundation

/// Reading a file from disk.
///
/// Exists so that `Data(contentsOf:)` does not occur in the project. He accepts
/// any URL and http address will silently go online - which means automatic
/// checking the network surface would not be able to distinguish between reading settings and
/// undeclared data sending. Here the address must be a file one.
public enum LocalFile {
    public enum Failure: Error, Sendable, Equatable {
        case notAFileURL(String)
        case unreadable(String)
    }

    /// Read the entire local file.
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
