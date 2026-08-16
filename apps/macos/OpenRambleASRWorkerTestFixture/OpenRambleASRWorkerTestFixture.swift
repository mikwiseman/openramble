import ASRWorkerProtocol
import Darwin
import Foundation

/// Native fault fixture for supervisor tests. It implements the worker
/// lifecycle without loading Core ML and can deterministically inject faults
/// at the private pipe boundary.
@main
enum OpenRambleASRWorkerTestFixture {
    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else { Darwin._exit(EX_USAGE) }
        let launchNumber = try recordProcessIdentifier(
            at: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        let mode = CommandLine.arguments.count == 3
            ? CommandLine.arguments[2]
            : "hang-inference"
        try ASRWireIO.disableSIGPIPE(on: STDOUT_FILENO)

        while let frame = try ASRWireIO.read(from: STDIN_FILENO) {
            switch frame.kind {
            case .hello:
                try respond(
                    kind: .helloAcknowledged,
                    requestID: frame.requestID,
                    value: ASRWorkerHelloAcknowledgement(
                        protocolVersion: ASRWorkerProtocol.version,
                        workerProcessIdentifier: getpid()
                    )
                )
            case .prepareMain:
                if mode == "hang-prepare" {
                    while true { _ = Darwin.pause() }
                }
                if mode == "slow-prepare" {
                    // A healthy specialization: long, but visibly burning CPU.
                    let spinUntil = ContinuousClock.now.advanced(by: .milliseconds(2_500))
                    var sink = 1.0
                    while ContinuousClock.now < spinUntil {
                        sink += (sink + 1).squareRoot()
                    }
                    if sink < 0 { Darwin._exit(EX_SOFTWARE) }
                }
                if mode == "disconnect-first-prepare", launchNumber == 1 {
                    Darwin._exit(EXIT_FAILURE)
                }
                try respond(
                    kind: .acknowledged,
                    requestID: frame.requestID,
                    value: ASRWorkerAcknowledgement()
                )
            case .warmInference:
                try respond(
                    kind: .acknowledged,
                    requestID: frame.requestID,
                    value: ASRWorkerAcknowledgement()
                )
                if mode == "exit-after-ready", launchNumber == 1 {
                    // Let the supervisor publish Ready first, then simulate an
                    // otherwise idle worker disappearing without a request in
                    // flight. This is the production window that used to leave
                    // AppState believing a dead generation was still warm.
                    usleep(20_000)
                    Darwin._exit(EXIT_FAILURE)
                }
            case .prepareVocabulary:
                let request = try ASRWorkerJSON.decode(
                    ASRWorkerVocabulary.self,
                    from: frame.metadata
                )
                try respond(
                    kind: .acknowledged,
                    requestID: frame.requestID,
                    value: ASRWorkerAcknowledgement(vocabularyRevision: request.revision)
                )
            case .unloadModels:
                if mode == "hang-unload" {
                    while true { _ = Darwin.pause() }
                }
                guard frame.payload.isEmpty, frame.metadata.isEmpty else {
                    Darwin._exit(EX_DATAERR)
                }
                try respond(
                    kind: .acknowledged,
                    requestID: frame.requestID,
                    value: ASRWorkerAcknowledgement()
                )
            case .transcribeSamples, .transcribeFile:
                try handleTranscription(
                    frame,
                    mode: mode,
                    launchNumber: launchNumber
                )
            case .shutdown:
                Darwin._exit(EXIT_SUCCESS)
            case .helloAcknowledged, .acknowledged, .result, .failure:
                Darwin._exit(EX_PROTOCOL)
            }
        }
    }

    private static func respond<Value: Encodable>(
        kind: ASRWireKind,
        requestID: UInt64,
        value: Value
    ) throws {
        try ASRWireIO.write(
            ASRWireFrame(
                kind: kind,
                requestID: requestID,
                metadata: ASRWorkerJSON.encode(value)
            ),
            to: STDOUT_FILENO
        )
    }

    private static func handleTranscription(
        _ frame: ASRWireFrame,
        mode: String,
        launchNumber: Int
    ) throws {
        switch mode {
        case "hang-inference":
            while true { _ = Darwin.pause() }
        case "hang-first-inference" where launchNumber == 1:
            while true { _ = Darwin.pause() }
        case "disconnect-first-inference" where launchNumber == 1:
            Darwin._exit(EXIT_FAILURE)
        case "malformed-first-inference" where launchNumber == 1:
            try writeRaw(Data(repeating: 0, count: 28))
            while true { _ = Darwin.pause() }
        case "truncated-first-inference" where launchNumber == 1:
            try writeRaw(Data([0x4f, 0x52, 0x41]))
            Darwin.close(STDOUT_FILENO)
            while true { _ = Darwin.pause() }
        case "success", "exit-after-ready", "hang-first-inference", "disconnect-first-inference",
             "malformed-first-inference", "truncated-first-inference":
            break
        default:
            Darwin._exit(EX_PROTOCOL)
        }

        let audioDuration: TimeInterval
        switch frame.kind {
        case .transcribeSamples:
            let request = try ASRWorkerJSON.decode(
                ASRWorkerTranscribeSamples.self,
                from: frame.metadata
            )
            guard request.sampleRate == ASRWorkerProtocol.sampleRate,
                  request.sampleCount > 0,
                  request.sampleCount <= ASRWorkerProtocol.maximumSamples,
                  request.sampleCount <= Int.max / MemoryLayout<Float>.size,
                  frame.payload.count == request.sampleCount * MemoryLayout<Float>.size
            else {
                Darwin._exit(EX_DATAERR)
            }
            audioDuration = Double(request.sampleCount) / Double(request.sampleRate)
        case .transcribeFile:
            let request = try ASRWorkerJSON.decode(
                ASRWorkerTranscribeFile.self,
                from: frame.metadata
            )
            guard frame.payload.isEmpty, request.path.hasPrefix("/") else {
                Darwin._exit(EX_DATAERR)
            }
            audioDuration = 0
        default:
            Darwin._exit(EX_PROTOCOL)
        }

        try respond(
            kind: .result,
            requestID: frame.requestID,
            value: ASRWorkerResult(
                text: "",
                words: [],
                audioDuration: audioDuration,
                processingDuration: 0
            )
        )
    }

    private static func writeRaw(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    STDOUT_FILENO,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
    }

    private static func recordProcessIdentifier(at url: URL) throws -> Int {
        let previousLaunches = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .count
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(getpid())\n".utf8))
        return previousLaunches + 1
    }
}
