import AgentBridge
import AppKit
import Darwin
import Foundation

private let toolName = "openramble_transcribe_audio"
private let protocolVersion = "2025-11-25"

// MARK: - Stdio MCP server

private final class MCPStdioServer: Sendable {
    private let dispatcher = MCPDispatcher()

    func run() async {
        var reader = BoundedLineReader(maximumBytes: AgentBridgeProtocol.defaultMaximumFrameBytes)
        while let input = reader.next() {
            switch input {
            case let .failure(error):
                await dispatcher.rejectInput(error)
            case let .success(data):
                guard !data.isEmpty else { continue }
                await dispatcher.accept(data)
            }
        }
        await dispatcher.shutdown()
    }
}

private enum StdioInputError: Error, Sendable {
    case requestTooLarge
    case unreadable
}

/// Reads newline-delimited JSON without allowing an MCP client to grow the
/// helper's memory without bound. Oversized lines are drained so a later valid
/// request on the same stdio connection can still be handled.
private struct BoundedLineReader {
    private let maximumBytes: Int
    private var buffer = Data()
    private var discardingOversizedLine = false
    private var isFinished = false

    init(maximumBytes: Int) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    mutating func next() -> Result<Data, StdioInputError>? {
        guard !isFinished else { return nil }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let following = buffer.index(after: newline)
                if discardingOversizedLine || buffer.distance(from: buffer.startIndex, to: newline) > maximumBytes {
                    buffer.removeSubrange(buffer.startIndex..<following)
                    discardingOversizedLine = false
                    return .failure(.requestTooLarge)
                }
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(buffer.startIndex..<following)
                if line.last == 0x0D { line.removeLast() }
                return .success(line)
            }

            if !discardingOversizedLine, buffer.count > maximumBytes {
                discardingOversizedLine = true
                buffer.removeAll(keepingCapacity: true)
            } else if discardingOversizedLine {
                buffer.removeAll(keepingCapacity: true)
            }

            var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
                continue
            }
            if count == 0 {
                if discardingOversizedLine {
                    discardingOversizedLine = false
                    buffer.removeAll()
                    return .failure(.requestTooLarge)
                }
                guard !buffer.isEmpty else { return nil }
                guard buffer.count <= maximumBytes else {
                    buffer.removeAll()
                    return .failure(.requestTooLarge)
                }
                let final = buffer
                buffer.removeAll()
                return .success(final)
            }
            if errno == EINTR { continue }
            isFinished = true
            return .failure(.unreadable)
        }
    }
}

private actor MCPDispatcher {
    private enum Lifecycle: Equatable {
        case cold
        case initializing
        case ready
    }

    private let writer = JSONRPCWriter()
    private var lifecycle = Lifecycle.cold
    private var pending: [RPCID: Task<RPCResponse?, Never>] = [:]

    func accept(_ data: Data) {
        let decoder = JSONDecoder()
        guard let value = try? decoder.decode(JSONValue.self, from: data) else {
            writer.send(RPCResponse.failure(id: nil, code: -32700, message: "Parse error"))
            return
        }
        if case .array = value {
            writer.send(RPCResponse.failure(id: nil, code: -32600, message: "Invalid Request"))
            return
        }
        guard case .object = value,
              let request = try? decoder.decode(RPCRequest.self, from: data) else {
            writer.send(RPCResponse.failure(id: nil, code: -32600, message: "Invalid Request"))
            return
        }
        handleSingle(request)
    }

    func rejectInput(_ error: StdioInputError) {
        let message = switch error {
        case .requestTooLarge: "Request exceeds the 4 MiB local MCP limit."
        case .unreadable: "The MCP input stream could not be read."
        }
        writer.send(RPCResponse.failure(id: nil, code: -32700, message: message))
    }

    func shutdown() async {
        let tasks = Array(pending.values)
        pending.removeAll()
        for task in tasks { task.cancel() }
        // Cancellation closes the private socket and runs the staging-file
        // defer. Do not let process exit race those privacy cleanups.
        for task in tasks { _ = await task.value }
    }

    private func handleSingle(_ request: RPCRequest) {
        switch dispatch(request) {
        case let .immediate(response):
            if let response { writer.send(response) }
        case let .deferred(id, task):
            Task { [weak self] in
                let response = await task.value
                await self?.finishSingle(id: id, response: response)
            }
        }
    }

    private func finishSingle(id: RPCID, response: RPCResponse?) {
        pending[id] = nil
        if let response { writer.send(response) }
    }

    private func dispatch(_ request: RPCRequest) -> RequestDispatch {
        guard request.jsonrpc == "2.0" else {
            return .immediate(.failure(id: request.id, code: -32600, message: "Invalid Request"))
        }

        if request.method == "notifications/initialized" {
            if lifecycle == .initializing { lifecycle = .ready }
            return .immediate(nil)
        }
        if request.method == "notifications/cancelled" {
            if let id = request.params?["requestId"]?.rpcID {
                pending[id]?.cancel()
            }
            return .immediate(nil)
        }
        guard let id = request.id else {
            // Unknown notifications never receive JSON-RPC responses.
            return .immediate(nil)
        }

        switch request.method {
        case "initialize":
            guard lifecycle == .cold else {
                return .immediate(.failure(id: id, code: -32600, message: "Already initialized"))
            }
            guard let requested = request.params?["protocolVersion"]?.stringValue,
                  request.params?["capabilities"]?.objectValue != nil,
                  request.params?["clientInfo"]?.objectValue != nil else {
                return .immediate(.failure(id: id, code: -32602, message: "Invalid initialize parameters"))
            }
            lifecycle = .initializing
            let selected = Self.supportedVersions.contains(requested)
                ? requested
                : protocolVersion
            return .immediate(.success(
                id: id,
                result: .object([
                    "protocolVersion": .string(selected),
                    "capabilities": .object([
                        "tools": .object(["listChanged": .bool(false)])
                    ]),
                    "serverInfo": .object([
                        "name": .string("openramble"),
                        "title": .string("OpenRamble Local Transcription"),
                        "version": .string(ContainingApplication.version)
                    ]),
                    "instructions": .string(
                        "Transcribe local audio files entirely on this Mac. Pass absolute file paths. Live dictation has priority."
                    )
                ])
            ))
        case "ping":
            return .immediate(.success(id: id, result: .object([:])))
        default:
            guard lifecycle == .ready else {
                return .immediate(.failure(id: id, code: -32600, message: "Initialize the MCP connection first."))
            }
            switch request.method {
            case "tools/list":
                return .immediate(.success(
                    id: id,
                    result: .object(["tools": .array([Self.transcriptionTool])])
                ))
            case "tools/call":
                guard pending[id] == nil else {
                    return .immediate(.failure(id: id, code: -32600, message: "Request id is already active."))
                }
                let task = Task { [writer] in
                    await Self.callTool(request, writer: writer)
                }
                pending[id] = task
                return .deferred(id: id, task: task)
            default:
                return .immediate(.failure(id: id, code: -32601, message: "Method not found"))
            }
        }
    }

    private static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", protocolVersion]

    private static var transcriptionTool: JSONValue {
        .object([
            "name": .string(toolName),
            "title": .string("Transcribe local audio"),
            "description": .string(
                "Transcribe one local audio file with OpenRamble's on-device model. Agent jobs are serialized and yield to live dictation."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Absolute path to a regular local audio file. Symbolic links are rejected."
                        )
                    ]),
                    "language": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional supported BCP-47 language hint such as en or ru. Omit for automatic mixed-language detection."
                        )
                    ]),
                    "timestamps": .object([
                        "type": .string("boolean"),
                        "description": .string("Return word timestamps when true. Defaults to false.")
                    ])
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false)
            ]),
            "outputSchema": Self.outputSchema,
            "annotations": .object([
                "title": .string("Transcribe local audio"),
                "readOnlyHint": .bool(true),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(true),
                "openWorldHint": .bool(false)
            ])
        ])
    }

    private static var outputSchema: JSONValue {
        let success: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object(["type": .string("string")]),
                "audioDurationSeconds": .object(["type": .string("number")]),
                "processingDurationSeconds": .object(["type": .string("number")]),
                "queueWaitSeconds": .object(["type": .string("number")]),
                "totalDurationSeconds": .object(["type": .string("number")]),
                "languageHint": .object([
                    "type": .array([.string("string"), .string("null")])
                ]),
                "words": .object([
                    "type": .array([.string("array"), .string("null")]),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object(["type": .string("string")]),
                            "startSeconds": .object(["type": .string("number")]),
                            "endSeconds": .object(["type": .string("number")]),
                            "confidence": .object([
                                "type": .array([.string("number"), .string("null")])
                            ])
                        ]),
                        "required": .array([
                            .string("text"), .string("startSeconds"), .string("endSeconds")
                        ])
                    ])
                ])
            ]),
            "required": .array([
                .string("text"), .string("audioDurationSeconds"),
                .string("processingDurationSeconds"), .string("queueWaitSeconds"),
                .string("totalDurationSeconds")
            ])
        ])
        let failure: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "error": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "code": .object(["type": .string("string")]),
                        "message": .object(["type": .string("string")]),
                        "retryable": .object(["type": .string("boolean")])
                    ]),
                    "required": .array([
                        .string("code"), .string("message"), .string("retryable")
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ]),
            "required": .array([.string("error")]),
            "additionalProperties": .bool(false)
        ])
        return .object(["oneOf": .array([success, failure])])
    }

    private static func callTool(
        _ request: RPCRequest,
        writer: JSONRPCWriter
    ) async -> RPCResponse? {
        guard let id = request.id else { return nil }
        guard let params = request.params,
              let requestedTool = params["name"]?.stringValue else {
            return .failure(id: id, code: -32602, message: "Malformed tools/call request")
        }
        guard requestedTool == toolName else {
            return .failure(id: id, code: -32602, message: "Unknown tool")
        }
        if params["task"] != nil {
            return .failure(id: id, code: -32601, message: "Task-augmented tool calls are not supported")
        }
        let arguments: [String: JSONValue]
        if let value = params["arguments"] {
            guard let object = value.objectValue else {
                return .failure(id: id, code: -32602, message: "Tool arguments must be an object")
            }
            arguments = object
        } else {
            arguments = [:]
        }
        guard Set(arguments.keys).isSubset(of: Set(["path", "language", "timestamps"])),
              let path = arguments["path"]?.stringValue else {
            return .failure(id: id, code: -32602, message: "Tool arguments do not match the input schema")
        }
        guard !path.isEmpty else {
            return toolError(
                id: id,
                code: "invalid_path",
                message: "path must be a non-empty absolute file path.",
                retryable: false
            )
        }
        if let languageValue = arguments["language"], languageValue.stringValue == nil {
            return .failure(id: id, code: -32602, message: "language must be a string")
        }
        if let timestampsValue = arguments["timestamps"], timestampsValue.boolValue == nil {
            return .failure(id: id, code: -32602, message: "timestamps must be a boolean")
        }
        let language = arguments["language"]?.stringValue
        let timestamps = arguments["timestamps"]?.boolValue ?? false
        let token = request.params?["_meta"]?.objectValue?["progressToken"]
        let reporter = MCPProgressReporter(writer: writer, token: token)
        do {
            let result = try await AppBridge.transcribe(
                sourcePath: path,
                languageHint: language,
                includesTimestamps: timestamps
            ) { stage in
                Task { await reporter.report(stage) }
            }
            try Task.checkCancellation()
            await reporter.finish()
            let structured = try JSONValue(result)
            return .success(
                id: id,
                result: .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(result.text)])
                    ]),
                    "structuredContent": structured,
                    "isError": .bool(false)
                ])
            )
        } catch {
            if Task.isCancelled { return nil }
            await reporter.finish()
            if let bridgeError = error as? AgentBridgeError {
                return toolError(
                    id: id,
                    code: bridgeError.code.rawValue,
                    message: bridgeError.message,
                    retryable: bridgeError.isRetryable
                )
            }
            if let socketError = error as? AgentBridgeSocketError {
                return socketToolError(id: id, error: socketError)
            }
            return toolError(
                id: id,
                code: "local_transport_error",
                message: "The local transcription bridge failed. Restart OpenRamble and retry.",
                retryable: true
            )
        }
    }

    private static func socketToolError(id: RPCID, error: AgentBridgeSocketError) -> RPCResponse {
        switch error {
        case .unavailable, .disconnected:
            toolError(
                id: id,
                code: "app_unavailable",
                message: "OpenRamble is unavailable or stopped responding. Open the app and retry.",
                retryable: true
            )
        case .permissionDenied:
            toolError(
                id: id,
                code: "local_transport_denied",
                message: "The private local bridge rejected this process.",
                retryable: false
            )
        case .pathTooLong, .runtimeDirectoryUnavailable, .alreadyRunning,
             .invalidMessage, .systemCall:
            toolError(
                id: id,
                code: "local_transport_error",
                message: "The private local bridge failed. Restart OpenRamble and retry.",
                retryable: true
            )
        }
    }

    private static func toolError(
        id: RPCID,
        code: String,
        message: String,
        retryable: Bool
    ) -> RPCResponse {
        .success(
            id: id,
            result: .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(message)])
                ]),
                "structuredContent": .object([
                    "error": .object([
                        "code": .string(code),
                        "message": .string(message),
                        "retryable": .bool(retryable)
                    ])
                ]),
                "isError": .bool(true)
            ])
        )
    }
}

private enum RequestDispatch {
    case immediate(RPCResponse?)
    case deferred(id: RPCID, task: Task<RPCResponse?, Never>)
}

private actor MCPProgressReporter {
    private let writer: JSONRPCWriter
    private let token: JSONValue?
    private var highest = -1.0

    init(writer: JSONRPCWriter, token: JSONValue?) {
        self.writer = writer
        self.token = token
    }

    func report(_ stage: AgentBridgeProgress) {
        let update: (Double, String)
        switch stage {
        case .queued: update = (0, "Queued")
        case .waitingForDictation: update = (10, "Waiting for live dictation")
        case .decoding: update = (25, "Decoding audio")
        case .transcribing: update = (50, "Transcribing locally")
        }
        send(progress: update.0, message: update.1)
    }

    func finish() {
        send(progress: 100, message: "Complete")
    }

    private func send(progress: Double, message: String) {
        guard progress > highest else { return }
        highest = progress
        guard let token else { return }
        writer.sendNotification(
            method: "notifications/progress",
            params: .object([
                "progressToken": token,
                "progress": .double(progress),
                "total": .double(100),
                "message": .string(message)
            ])
        )
    }
}

// MARK: - JSON-RPC primitives

private enum RPCID: Hashable, Codable, Sendable {
    case string(String)
    case integer(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON-RPC id")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        }
    }
}

private struct RPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: RPCID?
    let method: String
    let params: [String: JSONValue]?
}

private struct RPCResponse: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: RPCID?
    let result: JSONValue?
    let error: RPCErrorObject?

    static func success(id: RPCID, result: JSONValue) -> RPCResponse {
        RPCResponse(id: id, result: result, error: nil)
    }

    static func failure(id: RPCID?, code: Int, message: String) -> RPCResponse {
        RPCResponse(id: id, result: nil, error: RPCErrorObject(code: code, message: message))
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        if let result { try container.encode(result, forKey: .result) }
        if let error { try container.encode(error, forKey: .error) }
    }
}

private struct RPCErrorObject: Encodable, Sendable {
    let code: Int
    let message: String
}

private struct RPCNotification: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: JSONValue
}

private final class JSONRPCWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false

    func send<T: Encodable>(_ message: T) {
        lock.withLock {
            guard !isClosed else { return }
            guard var data = try? JSONEncoder().encode(message) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var written = 0
                while written < data.count {
                    let count = Darwin.write(
                        STDOUT_FILENO,
                        baseAddress.advanced(by: written),
                        data.count - written
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        isClosed = true
                        return
                    }
                    if count == 0 {
                        isClosed = true
                        return
                    }
                    written += count
                }
            }
        }
    }

    func sendNotification(method: String, params: JSONValue) {
        send(RPCNotification(method: method, params: params))
    }
}

private enum JSONValue: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init<T: Encodable>(_ value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var rpcID: RPCID? {
        switch self {
        case let .string(value): return .string(value)
        case let .integer(value): return .integer(value)
        default: return nil
        }
    }
}

// MARK: - App bridge

private enum AppBridge {
    static func transcribe(
        sourcePath: String,
        languageHint: String?,
        includesTimestamps: Bool,
        onProgress: @escaping UnixSocketClient.ProgressHandler
    ) async throws -> AgentTranscriptionResult {
        let appURL = ContainingApplication.locate()
        let bundleIdentifier = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
            ?? AgentBridgeSocketAddress.productionBundleIdentifier
        // The embedded executable's main bundle is the containing app. Passing
        // that same identifier as a suite is rejected by Foundation as a
        // nonsensical suite and silently reads false; `.standard` is the shared
        // application preference domain we need here.
        guard UserDefaults.standard.bool(
            forKey: AgentBridgeProtocol.accessPreferenceKey
        ) else {
            throw AgentBridgeError(
                code: .accessDisabled,
                message: "Agent transcription is disabled in OpenRamble Settings."
            )
        }
        let address = try AgentBridgeSocketAddress(bundleIdentifier: bundleIdentifier)

        if !UnixSocketClient.isReachable(address: address) {
            guard let appURL, await ApplicationLauncher.launch(appURL) else {
                throw AgentBridgeError(
                    code: .appUnavailable,
                    message: "OpenRamble could not be launched.",
                    isRetryable: true
                )
            }
            var becameReachable = false
            for _ in 0..<80 {
                try Task.checkCancellation()
                if UnixSocketClient.isReachable(address: address) {
                    becameReachable = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard becameReachable else {
                throw AgentBridgeError(
                    code: .appUnavailable,
                    message: "OpenRamble launched but its local transcription service is unavailable.",
                    isRetryable: true
                )
            }
        }
        let staged: AgentAudioStaging.File
        do {
            staged = try await Task.detached(priority: .utility) {
                try AgentAudioStaging.stage(sourcePath: sourcePath, address: address)
            }.value
        } catch let error as AudioFilePolicyError {
            throw filePolicyError(error)
        } catch {
            throw AgentBridgeError(
                code: .fileUnreadable,
                message: "The audio file could not be prepared for local transcription. Check access and retry."
            )
        }
        defer { AgentAudioStaging.remove(name: staged.name, address: address) }
        let request = AgentTranscriptionRequest(
            stagedFileName: staged.name,
            languageHint: languageHint,
            includesTimestamps: includesTimestamps
        )
        return try await UnixSocketClient.transcribe(request, address: address, onProgress: onProgress)
    }

    private static func filePolicyError(_ error: AudioFilePolicyError) -> AgentBridgeError {
        switch error {
        case .pathMustBeAbsolute, .symbolicLinksNotAllowed, .notARegularFile:
            AgentBridgeError(
                code: .invalidPath,
                message: "path must identify an absolute, regular local file without symbolic links."
            )
        case .unreadable:
            AgentBridgeError(
                code: .fileUnreadable,
                message: "The audio file is not readable by the MCP client. Check its permissions."
            )
        case .empty:
            AgentBridgeError(code: .invalidAudio, message: "The audio file is empty.")
        case let .tooLarge(_, maximum):
            AgentBridgeError(
                code: .fileTooLarge,
                message: "The audio file exceeds the \(maximum / 1_024 / 1_024) MiB local limit."
            )
        }
    }
}

private enum ContainingApplication {
    static var version: String {
        guard let appURL = locate() else { return "unknown" }
        return Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"
    }

    static func locate() -> URL? {
        var candidate = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        let installed = URL(fileURLWithPath: "/Applications/OpenRamble.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: installed.path) ? installed : nil
    }
}

@MainActor
private enum ApplicationLauncher {
    static func launch(_ applicationURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}

Darwin.signal(SIGPIPE, SIG_IGN)
await MCPStdioServer().run()
