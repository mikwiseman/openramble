import Foundation
import Testing

@testable import AgentBridge

@Suite("Private Unix socket bridge", .serialized)
struct UnixSocketTests {
    @Test("Client receives progress and result over the real byte stream")
    func roundTrip() async throws {
        let root = shortTemporaryDirectory(prefix: "sock")
        defer { try? FileManager.default.removeItem(at: root) }
        let address = try AgentBridgeSocketAddress(runtimeDirectory: root)
        let server = UnixSocketServer(address: address)
        try server.start { request, progress in
            progress(.decoding)
            return .result(
                requestID: request.requestID,
                result: AgentTranscriptionResult(
                    text: "local words",
                    audioDurationSeconds: 1,
                    processingDurationSeconds: 0.1,
                    queueWaitSeconds: 0,
                    totalDurationSeconds: 0.1,
                    languageHint: request.languageHint,
                    words: nil
                )
            )
        }
        defer { server.stop() }
        let progress = ProgressProbe()
        let request = AgentTranscriptionRequest(stagedFileName: "audio-test.wav", languageHint: "en")

        let result = try await UnixSocketClient.transcribe(request, address: address) { stage in
            progress.record(stage)
        }

        #expect(result.text == "local words")
        #expect(progress.values == [.decoding])
        let permissions = try FileManager.default.attributesOfItem(atPath: address.socket.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("An active server owns its socket")
    func exclusiveOwner() throws {
        let root = shortTemporaryDirectory(prefix: "sock")
        defer { try? FileManager.default.removeItem(at: root) }
        let address = try AgentBridgeSocketAddress(runtimeDirectory: root)
        let first = UnixSocketServer(address: address)
        let second = UnixSocketServer(address: address)
        try first.start { request, _ in
            .failure(requestID: request.requestID, error: AgentBridgeError(code: .busy, message: "Busy"))
        }
        defer { first.stop() }

        #expect(throws: AgentBridgeSocketError.alreadyRunning) {
            try second.start { request, _ in
                .failure(requestID: request.requestID, error: AgentBridgeError(code: .busy, message: "Busy"))
            }
        }
    }

    @Test("Client cancellation crosses the socket and leaves it reusable")
    func cancellation() async throws {
        let root = shortTemporaryDirectory(prefix: "cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let address = try AgentBridgeSocketAddress(runtimeDirectory: root)
        let server = UnixSocketServer(address: address)
        let probe = SocketCancellationProbe()
        try server.start { request, _ in
            await probe.runUntilCancelled()
            return .failure(
                requestID: request.requestID,
                error: AgentBridgeError(code: .cancelled, message: "Cancelled")
            )
        }
        defer { server.stop() }

        let request = AgentTranscriptionRequest(stagedFileName: "audio-test.wav")
        let client = Task {
            try await UnixSocketClient.transcribe(request, address: address)
        }
        await probe.waitUntilStarted()
        client.cancel()

        await #expect(throws: CancellationError.self) {
            try await client.value
        }
        await probe.waitUntilCancelled()
        #expect(UnixSocketClient.isReachable(address: address))
    }
}

private func shortTemporaryDirectory(prefix: String) -> URL {
    URL(
        fileURLWithPath: "/tmp/or-\(prefix)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
}

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentBridgeProgress] = []

    var values: [AgentBridgeProgress] { lock.withLock { storage } }

    func record(_ value: AgentBridgeProgress) {
        lock.withLock { storage.append(value) }
    }
}

private actor SocketCancellationProbe {
    private var started = false
    private var cancelled = false

    func runUntilCancelled() async {
        started = true
        while !Task.isCancelled { await Task.yield() }
        cancelled = true
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func waitUntilCancelled() async {
        while !cancelled { await Task.yield() }
    }
}
