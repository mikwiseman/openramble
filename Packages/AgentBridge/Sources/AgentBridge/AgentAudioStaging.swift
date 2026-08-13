import Darwin
import Foundation

public enum AgentAudioStagingError: Error, Equatable, Sendable {
    case invalidName
    case stagingUnavailable
    case permissionDenied
    case copyFailed(code: Int32)
}

/// Moves the filesystem access boundary into the MCP helper. The helper can
/// read the file selected by its parent agent, while the app may not have TCC
/// access to Documents, Desktop, or a cloud-provider folder. Only a private,
/// same-UID staging basename crosses the socket.
public enum AgentAudioStaging {
    private static let prefix = "audio-"

    public struct File: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let byteCount: UInt64

        fileprivate init(name: String, url: URL, byteCount: UInt64) {
            self.name = name
            self.url = url
            self.byteCount = byteCount
        }
    }

    public static func prepareDirectory(address: AgentBridgeSocketAddress) throws {
        try FileManager.default.createDirectory(
            at: address.stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = try openOwnedDirectory(address.stagingDirectory)
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRWXU) == 0 else {
            throw AgentAudioStagingError.permissionDenied
        }
    }

    /// Copies the source through already-open file descriptors. On APFS,
    /// `fclonefileat` is copy-on-write and essentially constant-time; the data-
    /// only fallback supports other local filesystems.
    public static func stage(
        sourcePath: String,
        address: AgentBridgeSocketAddress,
        maximumBytes: UInt64 = AgentBridgeProtocol.defaultMaximumFileBytes
    ) throws -> File {
        guard sourcePath.hasPrefix("/") else {
            throw AudioFilePolicyError.pathMustBeAbsolute
        }
        let source = Darwin.open(sourcePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard source >= 0 else {
            if errno == ELOOP { throw AudioFilePolicyError.symbolicLinksNotAllowed }
            throw AudioFilePolicyError.unreadable
        }
        defer { Darwin.close(source) }

        var sourceMetadata = stat()
        guard fstat(source, &sourceMetadata) == 0 else {
            throw AudioFilePolicyError.unreadable
        }
        guard (sourceMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw AudioFilePolicyError.notARegularFile
        }
        let byteCount = UInt64(sourceMetadata.st_size)
        guard byteCount > 0 else { throw AudioFilePolicyError.empty }
        guard byteCount <= maximumBytes else {
            throw AudioFilePolicyError.tooLarge(actual: byteCount, maximum: maximumBytes)
        }

        let directory = try openDirectory(address.stagingDirectory)
        defer { Darwin.close(directory) }
        let name = stagedName(sourcePath: sourcePath)

        let cloned = name.withCString { pointer in
            fclonefileat(source, directory, pointer, 0)
        }
        if cloned != 0 {
            let destination = name.withCString { pointer in
                openat(
                    directory,
                    pointer,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard destination >= 0 else {
                throw AgentAudioStagingError.copyFailed(code: errno)
            }
            var copyError: Int32?
            if fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_DATA)) != 0 {
                copyError = errno
            } else if fchmod(destination, S_IRUSR | S_IWUSR) != 0 {
                copyError = errno
            }
            Darwin.close(destination)
            if let copyError {
                name.withCString { _ = unlinkat(directory, $0, 0) }
                throw AgentAudioStagingError.copyFailed(code: copyError)
            }
        } else {
            let destination = name.withCString {
                openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard destination >= 0 else {
                name.withCString { _ = unlinkat(directory, $0, 0) }
                throw AgentAudioStagingError.copyFailed(code: errno)
            }
            let permissionResult = fchmod(destination, S_IRUSR | S_IWUSR)
            let permissionError = errno
            Darwin.close(destination)
            guard permissionResult == 0 else {
                name.withCString { _ = unlinkat(directory, $0, 0) }
                throw AgentAudioStagingError.copyFailed(code: permissionError)
            }
        }

        return File(
            name: name,
            url: address.stagingDirectory.appending(path: name, directoryHint: .notDirectory),
            byteCount: byteCount
        )
    }

    public static func validate(
        name: String,
        address: AgentBridgeSocketAddress,
        maximumBytes: UInt64 = AgentBridgeProtocol.defaultMaximumFileBytes
    ) throws -> ValidatedAudioFile {
        guard isValidName(name) else { throw AgentAudioStagingError.invalidName }
        let directory = try openDirectory(address.stagingDirectory)
        defer { Darwin.close(directory) }
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw AudioFilePolicyError.unreadable }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw AudioFilePolicyError.unreadable
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid() else {
            throw AudioFilePolicyError.notARegularFile
        }
        let byteCount = UInt64(metadata.st_size)
        guard byteCount > 0 else { throw AudioFilePolicyError.empty }
        guard byteCount <= maximumBytes else {
            throw AudioFilePolicyError.tooLarge(actual: byteCount, maximum: maximumBytes)
        }
        return ValidatedAudioFile(
            url: address.stagingDirectory.appending(path: name, directoryHint: .notDirectory),
            byteCount: byteCount
        )
    }

    public static func remove(name: String, address: AgentBridgeSocketAddress) {
        guard isValidName(name),
              let directory = try? openDirectory(address.stagingDirectory) else { return }
        defer { Darwin.close(directory) }
        name.withCString { pointer in
            if unlinkat(directory, pointer, 0) != 0, errno != ENOENT {
                // Cleanup is deliberately best-effort and never exposes a path.
            }
        }
    }

    static func removeAbandonedFiles(address: AgentBridgeSocketAddress) throws {
        let directory = try openDirectory(address.stagingDirectory)
        defer { Darwin.close(directory) }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: address.stagingDirectory.path
        )
        for name in names where isValidName(name) {
            name.withCString { _ = unlinkat(directory, $0, 0) }
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = try openOwnedDirectory(url)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            Darwin.close(descriptor)
            throw AgentAudioStagingError.permissionDenied
        }
        return descriptor
    }

    private static func openOwnedDirectory(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AgentAudioStagingError.stagingUnavailable
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid() else {
            Darwin.close(descriptor)
            throw AgentAudioStagingError.permissionDenied
        }
        return descriptor
    }

    private static func stagedName(sourcePath: String) -> String {
        let sourceExtension = URL(fileURLWithPath: sourcePath).pathExtension
        let isSafeExtension = !sourceExtension.isEmpty
            && sourceExtension.utf8.count <= 10
            && sourceExtension.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
        let suffix = isSafeExtension ? ".\(sourceExtension.lowercased())" : ".audio"
        return "\(prefix)\(UUID().uuidString)\(suffix)"
    }

    private static func isValidName(_ name: String) -> Bool {
        guard name.utf8.count <= 64, !name.utf8.contains(0), !name.contains("/") else {
            return false
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].hasPrefix(prefix),
              UUID(uuidString: String(parts[0].dropFirst(prefix.count))) != nil,
              !parts[1].isEmpty,
              parts[1].utf8.count <= 10,
              parts[1].unicodeScalars.allSatisfy({
                  $0.isASCII && CharacterSet.alphanumerics.contains($0)
              }) else {
            return false
        }
        return true
    }
}
