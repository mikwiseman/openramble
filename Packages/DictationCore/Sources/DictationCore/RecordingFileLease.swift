import Darwin
import Foundation

/// Kernel-owned liveness for an in-progress recording.
///
/// Modification time is not ownership: a filesystem call or audio callback can
/// remain wedged longer than any finite freshness window. `flock` is released
/// automatically when the owning descriptor closes or its process dies, so a
/// second debug/release instance can distinguish a live writer from a crash
/// artifact without trusting a timer or a PID file.
public enum RecordingFileLease {
    public enum Failure: Error, Sendable, Equatable {
        case systemCall(operation: String, code: Int32)
    }

    /// An owned exclusive lease. Recovery keeps this object alive across the
    /// complete inspect/repair/move decision so another process cannot become
    /// a writer in the gap between a liveness probe and destructive I/O.
    public final class Claim: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        public func release() {
            let owned: Int32? = lock.withLock {
                defer { descriptor = nil }
                return descriptor
            }
            guard let owned else { return }
            _ = flock(owned, LOCK_UN)
            _ = Darwin.close(owned)
        }

        deinit { release() }
    }

    /// Hold an exclusive lease for the lifetime of `handle`.
    public static func acquireExclusive(on handle: FileHandle) throws {
        while flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw Failure.systemCall(operation: "flock(LOCK_EX)", code: code)
        }
    }

    /// Claim an existing file without waiting. `nil` is deliberately
    /// conservative: the path is missing, another process owns it, or the OS
    /// would not let us prove exclusive ownership. Callers must skip mutation
    /// in every one of those cases.
    public static func claimExclusiveIfAvailable(at url: URL) -> Claim? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            _ = Darwin.close(descriptor)
            return nil
        }
        return Claim(descriptor: descriptor)
    }

    /// Conservatively report whether another open description owns the file.
    /// An unreadable path is treated as unavailable/live rather than risking
    /// repair or deletion of bytes whose ownership cannot be proved.
    public static func isActivelyHeld(at url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return errno != ENOENT }
        defer { Darwin.close(descriptor) }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            // EWOULDBLOCK/EAGAIN is a live owner; every other error means we
            // cannot safely prove abandonment either.
            return true
        }
        _ = flock(descriptor, LOCK_UN)
        return false
    }
}
