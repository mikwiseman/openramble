import Darwin
import Foundation

public enum AgentBridgeSocketError: Error, Equatable, Sendable {
    case pathTooLong
    case runtimeDirectoryUnavailable
    case alreadyRunning
    case unavailable
    case permissionDenied
    case disconnected
    case invalidMessage
    case systemCall(operation: String, code: Int32)
}

public struct AgentBridgeSocketAddress: Equatable, Sendable {
    public static let productionBundleIdentifier = "is.waiwai.dictation"
    public static let developmentBundleIdentifier = "is.waiwai.dictation.dev"

    public let directory: URL
    public let socket: URL
    public let stagingDirectory: URL

    public init(bundleIdentifier: String) throws {
        guard let temporaryDirectory = Self.darwinUserTemporaryDirectory() else {
            throw AgentBridgeSocketError.runtimeDirectoryUnavailable
        }
        let namespace = bundleIdentifier == Self.developmentBundleIdentifier
            ? Self.developmentBundleIdentifier
            : Self.productionBundleIdentifier
        try self.init(
            runtimeDirectory: temporaryDirectory.appending(path: namespace, directoryHint: .isDirectory)
        )
    }

    /// Test seam for an isolated runtime namespace. Product code always uses
    /// the bundle-identifier initializer above.
    init(runtimeDirectory directory: URL) throws {
        let socket = directory.appending(path: "agent-v1.sock")
        guard socket.path.utf8.count < Self.maximumPathBytes else {
            throw AgentBridgeSocketError.pathTooLong
        }
        self.directory = directory
        self.socket = socket
        stagingDirectory = directory.appending(path: "incoming", directoryHint: .isDirectory)
    }

    public static var maximumPathBytes: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    private static func darwinUserTemporaryDirectory() -> URL? {
        let requiredBytes = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard requiredBytes > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: requiredBytes)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, requiredBytes) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return URL(fileURLWithPath: String(cString: baseAddress), isDirectory: true)
        }
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public typealias ProgressSink = @Sendable (AgentBridgeProgress) -> Void
    public typealias Handler = @Sendable (
        AgentTranscriptionRequest,
        @escaping ProgressSink
    ) async -> AgentBridgeServerMessage

    private let address: AgentBridgeSocketAddress
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var acceptThread: Thread?
    private var acceptFinished: DispatchSemaphore?

    public init(address: AgentBridgeSocketAddress) {
        self.address = address
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping Handler) throws {
        let listener = try Self.makeListeningSocket(address: address)
        let finished = DispatchSemaphore(value: 0)
        let socketURL = address.socket
        let thread = Thread { [weak self] in
            defer {
                Darwin.close(listener)
                try? FileManager.default.removeItem(at: socketURL)
                finished.signal()
            }
            while self?.owns(listener: listener) == true {
                let connection = Darwin.accept(listener, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard self?.owns(listener: listener) == true else {
                    Darwin.close(connection)
                    return
                }
                Task {
                    await Self.serve(connection: connection, handler: handler)
                }
            }
        }
        thread.name = "OpenRamble agent socket accept"
        thread.qualityOfService = .utility
        let accepted = lock.withLock { () -> Bool in
            guard descriptor == -1 else { return false }
            descriptor = listener
            acceptThread = thread
            acceptFinished = finished
            return true
        }
        guard accepted else {
            Darwin.close(listener)
            throw AgentBridgeSocketError.alreadyRunning
        }
        thread.start()
    }

    public func stop() {
        let state = lock.withLock { () -> (Int32, Thread?, DispatchSemaphore?) in
            let old = (descriptor, acceptThread, acceptFinished)
            descriptor = -1
            acceptThread = nil
            acceptFinished = nil
            return old
        }
        guard state.0 >= 0 else { return }

        // The accept thread owns close(). A same-user self-connect wakes it
        // without making the descriptor number available for reuse while
        // accept() can still be running on it.
        Self.wakeListener(at: address.socket.path)
        Darwin.shutdown(state.0, SHUT_RDWR)
        if state.1 !== Thread.current {
            _ = state.2?.wait(timeout: .now() + 2)
        }
    }

    private func owns(listener: Int32) -> Bool {
        lock.withLock { descriptor == listener }
    }

    private static func serve(connection: Int32, handler: @escaping Handler) async {
        let handle = SocketHandle(descriptor: connection)
        let reader = SocketFrameReader(descriptor: connection)
        let request: AgentTranscriptionRequest
        do {
            try configureConnectedSocket(connection)
            try verifySameUser(connection)
            let payload = try await BlockingIO.run { try reader.next() }
            let message = try JSONDecoder().decode(AgentBridgeClientMessage.self, from: payload)
            guard case let .transcribe(decodedRequest) = message else {
                throw AgentBridgeSocketError.invalidMessage
            }
            request = decodedRequest
        } catch {
            handle.close()
            return
        }

        let writer = SocketWriter(descriptor: connection)
        let work = Task {
            await handler(request) { stage in
                writer.enqueue(
                    .progress(requestID: request.requestID, stage: stage)
                )
            }
        }
        let monitor = Task {
            do {
                let cancellationPayload = try await BlockingIO.run { try reader.next() }
                let cancellation = try JSONDecoder().decode(
                    AgentBridgeClientMessage.self,
                    from: cancellationPayload
                )
                if case let .cancel(requestID) = cancellation,
                   requestID == request.requestID {
                    work.cancel()
                }
            } catch {
                work.cancel()
            }
        }
        let response = await work.value
        try? await writer.send(response)
        handle.shutdown()
        await monitor.value
        handle.close()
    }

    private static func makeListeningSocket(address: AgentBridgeSocketAddress) throws -> Int32 {
        try prepareRuntimeDirectory(address.directory)
        try AgentAudioStaging.prepareDirectory(address: address)
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw AgentBridgeSocketError.systemCall(operation: "socket", code: errno)
        }
        do {
            try configureConnectedSocket(listener)
            var socketAddress = try makeSockaddr(path: address.socket.path)
            let socketAddressLength = socklen_t(socketAddress.sun_len)
            let result = withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socketAddressLength)
                }
            }
            if result != 0, errno == EADDRINUSE {
                if isServerReachable(at: address.socket.path) {
                    throw AgentBridgeSocketError.alreadyRunning
                }
                guard unlink(address.socket.path) == 0 || errno == ENOENT else {
                    throw AgentBridgeSocketError.systemCall(operation: "unlink", code: errno)
                }
                let retry = withUnsafePointer(to: &socketAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(listener, $0, socketAddressLength)
                    }
                }
                guard retry == 0 else {
                    throw AgentBridgeSocketError.systemCall(operation: "bind", code: errno)
                }
            } else if result != 0 {
                throw AgentBridgeSocketError.systemCall(operation: "bind", code: errno)
            }
            // Binding establishes exclusive ownership while the socket is not
            // accepting clients yet, making this the safe point to remove
            // abandoned transfers from an earlier crash.
            try AgentAudioStaging.removeAbandonedFiles(address: address)
            guard chmod(address.socket.path, S_IRUSR | S_IWUSR) == 0 else {
                throw AgentBridgeSocketError.systemCall(operation: "chmod", code: errno)
            }
            guard Darwin.listen(listener, 16) == 0 else {
                throw AgentBridgeSocketError.systemCall(operation: "listen", code: errno)
            }
            return listener
        } catch {
            Darwin.close(listener)
            throw error
        }
    }

    private static func prepareRuntimeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid() else {
            throw AgentBridgeSocketError.permissionDenied
        }
        guard chmod(directory.path, S_IRWXU) == 0 else {
            throw AgentBridgeSocketError.systemCall(operation: "chmod", code: errno)
        }
    }

    private static func isServerReachable(at path: String) -> Bool {
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return true }
        defer { Darwin.close(probe) }
        guard var socketAddress = try? makeSockaddr(path: path) else { return true }
        let socketAddressLength = socklen_t(socketAddress.sun_len)
        let result = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socketAddressLength)
            }
        }
        return result == 0
    }

    private static func wakeListener(at path: String) {
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return }
        defer { Darwin.close(probe) }
        guard var socketAddress = try? makeSockaddr(path: path) else { return }
        let length = socklen_t(socketAddress.sun_len)
        withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.connect(probe, $0, length)
            }
        }
    }
}

public enum UnixSocketClient {
    public typealias ProgressHandler = @Sendable (AgentBridgeProgress) -> Void

    public static func transcribe(
        _ request: AgentTranscriptionRequest,
        address: AgentBridgeSocketAddress,
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> AgentTranscriptionResult {
        let handle = SocketHandle()
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await BlockingIO.run {
                let descriptor = try connect(address: address)
                guard handle.install(descriptor) else { throw CancellationError() }
                defer { handle.close() }
                try handle.send(.transcribe(request))
                let reader = SocketFrameReader(descriptor: descriptor)

                while true {
                    let payload = try reader.next()
                    let message = try JSONDecoder().decode(AgentBridgeServerMessage.self, from: payload)
                    switch message {
                    case let .progress(requestID, stage) where requestID == request.requestID:
                        onProgress(stage)
                    case let .result(requestID, result) where requestID == request.requestID:
                        return result
                    case let .failure(requestID, error) where requestID == request.requestID:
                        throw error
                    default:
                        throw AgentBridgeSocketError.invalidMessage
                    }
                }
                }
            } onCancel: {
                handle.cancel(requestID: request.requestID)
            }
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    public static func isReachable(address: AgentBridgeSocketAddress) -> Bool {
        guard let descriptor = try? connect(address: address) else { return false }
        Darwin.close(descriptor)
        return true
    }

    private static func connect(address: AgentBridgeSocketAddress) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AgentBridgeSocketError.systemCall(operation: "socket", code: errno)
        }
        do {
            try configureConnectedSocket(descriptor)
            var socketAddress = try makeSockaddr(path: address.socket.path)
            let socketAddressLength = socklen_t(socketAddress.sun_len)
            let result = withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socketAddressLength)
                }
            }
            guard result == 0 else {
                if errno == EACCES { throw AgentBridgeSocketError.permissionDenied }
                throw AgentBridgeSocketError.unavailable
            }
            try verifySameUser(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}

private final class SocketHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var shutdownRequested = false

    init(descriptor: Int32 = -1) {
        self.descriptor = descriptor
    }

    @discardableResult
    func install(_ newDescriptor: Int32) -> Bool {
        let shouldClose = lock.withLock { () -> Bool in
            guard !shutdownRequested, descriptor == -1 else { return true }
            descriptor = newDescriptor
            return false
        }
        if shouldClose { Darwin.close(newDescriptor) }
        return !shouldClose
    }

    func send(_ message: AgentBridgeClientMessage) throws {
        try lock.withLock {
            guard descriptor >= 0, !shutdownRequested else { throw CancellationError() }
            try writeMessage(message, to: descriptor)
        }
    }

    func cancel(requestID: UUID) {
        lock.withLock {
            shutdownRequested = true
            guard descriptor >= 0 else { return }
            try? writeMessage(
                AgentBridgeClientMessage.cancel(requestID: requestID),
                to: descriptor
            )
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    func shutdown() {
        lock.withLock {
            shutdownRequested = true
            if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }

    func close() {
        let old = lock.withLock { () -> Int32 in
            shutdownRequested = true
            let old = descriptor
            descriptor = -1
            return old
        }
        guard old >= 0 else { return }
        Darwin.shutdown(old, SHUT_RDWR)
        Darwin.close(old)
    }
}

private final class SocketWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "is.waiwai.dictation.agent-socket-writer", qos: .utility)

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func enqueue(_ message: AgentBridgeServerMessage) {
        queue.async { [descriptor] in
            try? writeMessage(message, to: descriptor)
        }
    }

    func send(_ message: AgentBridgeServerMessage) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [descriptor] in
                continuation.resume(with: Result {
                    try writeMessage(message, to: descriptor)
                })
            }
        }
    }
}

private enum BlockingIO {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}

private final class SocketFrameReader: @unchecked Sendable {
    private let descriptor: Int32
    private var decoder = LengthPrefixedFrameDecoder()
    private var ready: [Data] = []

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func next() throws -> Data {
        if !ready.isEmpty { return ready.removeFirst() }
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { throw AgentBridgeSocketError.disconnected }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeSocketError.systemCall(operation: "read", code: errno)
            }
            ready.append(contentsOf: try decoder.append(Data(bytes[0..<count])))
            if !ready.isEmpty { return ready.removeFirst() }
        }
    }
}

private func makeSockaddr(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, bytes.count < AgentBridgeSocketAddress.maximumPathBytes else {
        throw AgentBridgeSocketError.pathTooLong
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count + 1)
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.initializeMemory(as: UInt8.self, repeating: 0)
        storage.copyBytes(from: bytes)
    }
    return address
}

private func configureConnectedSocket(_ descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        throw AgentBridgeSocketError.systemCall(operation: "setsockopt", code: errno)
    }
}

private func verifySameUser(_ descriptor: Int32) throws {
    var peerUser = uid_t.max
    var peerGroup = gid_t.max
    guard getpeereid(descriptor, &peerUser, &peerGroup) == 0 else {
        throw AgentBridgeSocketError.systemCall(operation: "getpeereid", code: errno)
    }
    guard peerUser == getuid() else { throw AgentBridgeSocketError.permissionDenied }
}

private func writeMessage<Message: Encodable>(_ message: Message, to descriptor: Int32) throws {
    let payload = try JSONEncoder().encode(message)
    let frame = try LengthPrefixedFrameEncoder.encode(payload)
    try frame.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var written = 0
        while written < frame.count {
            let count = Darwin.write(
                descriptor,
                baseAddress.advanced(by: written),
                frame.count - written
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeSocketError.systemCall(operation: "write", code: errno)
            }
            if count == 0 { throw AgentBridgeSocketError.disconnected }
            written += count
        }
    }
}
