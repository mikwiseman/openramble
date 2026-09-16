import Darwin
import Foundation

/// One process-owned POSIX lock signals interactive dictation. CLI probes use
/// F_GETLK without acquiring the lock, so they can never delay key-down.
/// Keep one instance per process: closing any descriptor for a POSIX-locked
/// inode releases that process's locks. Never unlink the rendezvous file.
public final class DictationPriority: @unchecked Sendable {
    private let descriptor: Int32
    private let mutex = NSLock()
    private var held = false

    public init(url: URL? = nil) throws {
        let location: URL
        if let url { location = url }
        else {
            location = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "OpenRamble/dictation-priority.lock")
        }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(location.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Self.failure() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
    }

    deinit { close(descriptor) }

    public func setActive(_ active: Bool) throws {
        try mutex.withLock {
            guard active != held else { return }
            var claim = Self.claim(type: active ? F_WRLCK : F_UNLCK)
            guard fcntl(descriptor, F_SETLK, &claim) == 0 else { throw Self.failure() }
            held = active
        }
    }

    public func isActive() throws -> Bool {
        try mutex.withLock {
            if held { return true }
            var query = Self.claim(type: F_WRLCK)
            guard fcntl(descriptor, F_GETLK, &query) == 0 else { throw Self.failure() }
            return query.l_type != F_UNLCK
        }
    }

    public func waitForTurn() async throws {
        while try isActive() {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func claim(type: Int32) -> flock {
        flock(l_start: 0, l_len: 1, l_pid: 0, l_type: Int16(type), l_whence: Int16(SEEK_SET))
    }

    private static func failure() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
