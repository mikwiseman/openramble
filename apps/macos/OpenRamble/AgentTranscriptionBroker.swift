import AgentBridge
import DictationCore
import Foundation
import LocalASR

struct AgentInference: Sendable {
    let result: ASRResult
}

/// Owns the background lane into the one local recognizer. Agent requests are
/// serialized; live dictation bypasses this lane and synchronously reserves it.
final class AgentTranscriptionBroker: @unchecked Sendable {
    typealias BusyHandler = @Sendable (_ isBusy: Bool, _ usedEngine: Bool) -> Void

    private let transcriber: LocalTranscriber
    private let engineDirectory: URL
    private let bridgeAddress: AgentBridgeSocketAddress
    private let isEnabled: @Sendable () -> Bool
    private let scheduler: BackgroundScheduler<AgentInference>
    private let activity: AgentRequestActivity

    init(
        transcriber: LocalTranscriber,
        engineDirectory: URL,
        bridgeAddress: AgentBridgeSocketAddress,
        isEnabled: @escaping @Sendable () -> Bool,
        maximumQueued: Int = 4,
        onBusyChanged: @escaping BusyHandler = { _, _ in }
    ) {
        self.transcriber = transcriber
        self.engineDirectory = engineDirectory
        self.bridgeAddress = bridgeAddress
        self.isEnabled = isEnabled
        let reservation = InteractiveReservation()
        scheduler = BackgroundScheduler(maximumQueued: maximumQueued, reservation: reservation)
        activity = AgentRequestActivity(onChange: onBusyChanged)
    }

    func beginInteractiveWork() {
        scheduler.beginInteractiveWork()
    }

    func endInteractiveWork() {
        scheduler.endInteractiveWork()
    }

    func waitUntilInteractiveReady() async throws {
        try await scheduler.waitUntilInteractiveReady()
    }

    func handle(
        request: AgentTranscriptionRequest,
        progress: @escaping UnixSocketServer.ProgressSink
    ) async -> AgentBridgeServerMessage {
        activity.begin()
        defer { activity.end() }
        let totalStarted = ContinuousClock.now

        do {
            guard request.protocolVersion == AgentBridgeProtocol.version else {
                throw AgentBridgeError(
                    code: .protocolMismatch,
                    message: "The OpenRamble app and MCP helper use different protocol versions."
                )
            }
            // The app is the second cleanup owner. Install this before every
            // policy gate so a helper killed after sending cannot leave audio
            // behind on a disabled or rejected request.
            defer {
                AgentAudioStaging.remove(
                    name: request.stagedFileName,
                    address: bridgeAddress
                )
            }
            guard isEnabled() else {
                throw AgentBridgeError(
                    code: .accessDisabled,
                    message: "Agent transcription is disabled in OpenRamble Settings."
                )
            }
            if let languageHint = request.languageHint,
               !FluidAudioAdapter.supportedLanguageHints.contains(languageHint) {
                throw AgentBridgeError(
                    code: .invalidLanguage,
                    message: "Unsupported language hint. Use a supported BCP-47 code or automatic detection."
                )
            }
            let file: ValidatedAudioFile
            do {
                file = try AgentAudioStaging.validate(
                    name: request.stagedFileName,
                    address: bridgeAddress
                )
            } catch {
                throw Self.filePolicyError(error)
            }

            progress(.queued)
            if scheduler.isInteractiveReserved { progress(.waitingForDictation) }
            let scheduled = try await scheduler.submit(id: request.requestID) {
                progress(.decoding)
                let decode = Task.detached(priority: .utility) {
                    try AudioFileReader().samples(
                        from: file.url,
                        maximumDuration: AgentBridgeProtocol.defaultMaximumAudioSeconds
                    )
                }
                let samples = try await withTaskCancellationHandler {
                    try await decode.value
                } onCancel: {
                    decode.cancel()
                }
                try Task.checkCancellation()

                progress(.transcribing)
                self.activity.markEngineUse()
                try await self.transcriber.prepare(modelDirectory: self.engineDirectory)
                let result = try await self.transcriber.transcribe(
                    samples: samples,
                    languageHint: request.languageHint
                )
                return AgentInference(result: result)
            }

            let result = scheduled.output.result
            let words = request.includesTimestamps
                ? result.words.map {
                    AgentTranscriptionWord(
                        text: $0.text,
                        startSeconds: $0.start,
                        endSeconds: $0.end,
                        confidence: $0.confidence
                    )
                }
                : nil
            return .result(
                requestID: request.requestID,
                result: AgentTranscriptionResult(
                    text: result.text,
                    audioDurationSeconds: result.audioDuration,
                    processingDurationSeconds: result.processingDuration,
                    queueWaitSeconds: scheduled.queueWait.seconds,
                    totalDurationSeconds: totalStarted.duration(to: .now).seconds,
                    languageHint: request.languageHint,
                    words: words
                )
            )
        } catch is CancellationError {
            return .failure(
                requestID: request.requestID,
                error: AgentBridgeError(
                    code: .cancelled,
                    message: "Transcription was cancelled.",
                    isRetryable: true
                )
            )
        } catch let error as AgentBridgeError {
            return .failure(requestID: request.requestID, error: error)
        } catch let error as BackgroundSchedulerError {
            return .failure(requestID: request.requestID, error: Self.schedulerError(error))
        } catch let error as AudioFileReader.Failure {
            return .failure(requestID: request.requestID, error: Self.audioError(error))
        } catch let error as ASREngineError {
            return .failure(requestID: request.requestID, error: Self.engineError(error))
        } catch {
            return .failure(
                requestID: request.requestID,
                error: AgentBridgeError(
                    code: .transcriptionFailed,
                    message: "Local transcription failed. Retry the recording or check the model in OpenRamble."
                )
            )
        }
    }

    private static func filePolicyError(_ error: Error) -> AgentBridgeError {
        switch error as? AudioFilePolicyError {
        case .tooLarge:
            return AgentBridgeError(
                code: .fileTooLarge,
                message: "The audio file is larger than the local transcription limit."
            )
        case .pathMustBeAbsolute, .symbolicLinksNotAllowed, .notARegularFile:
            return AgentBridgeError(
                code: .invalidPath,
                message: "Pass an absolute path to a regular audio file; symbolic links are not accepted."
            )
        case .unreadable, .empty:
            return AgentBridgeError(code: .fileUnreadable, message: "The audio file is empty or unreadable.")
        case nil:
            return AgentBridgeError(code: .fileUnreadable, message: "The audio file could not be inspected.")
        }
    }

    private static func schedulerError(_ error: BackgroundSchedulerError) -> AgentBridgeError {
        switch error {
        case .queueFull:
            return AgentBridgeError(
                code: .busy,
                message: "The local transcription queue is full. Retry shortly.",
                isRetryable: true
            )
        case .preemptedByInteractiveWork:
            return AgentBridgeError(
                code: .preemptedByDictation,
                message: "Live dictation took priority. Retry this recording.",
                isRetryable: true
            )
        case .shuttingDown:
            return AgentBridgeError(
                code: .serverShuttingDown,
                message: "OpenRamble is shutting down. Retry after it relaunches.",
                isRetryable: true
            )
        }
    }

    private static func audioError(_ error: AudioFileReader.Failure) -> AgentBridgeError {
        switch error {
        case .durationExceeded:
            return AgentBridgeError(
                code: .audioTooLong,
                message: "Audio longer than 30 minutes must be split into smaller recordings."
            )
        case .emptyFile, .unreadable, .conversionFailed:
            return AgentBridgeError(
                code: .invalidAudio,
                message: "The file is not supported audio or could not be decoded."
            )
        }
    }

    private static func engineError(_ error: ASREngineError) -> AgentBridgeError {
        switch error {
        case .modelsNotLoaded:
            return AgentBridgeError(code: .engineLoading, message: "The local model is still loading.", isRetryable: true)
        case .modelsUnavailable:
            return AgentBridgeError(code: .modelNotInstalled, message: "Install or repair the local model in OpenRamble Settings.")
        case .unsupportedAudioFormat:
            return AgentBridgeError(code: .invalidAudio, message: "The audio format is not supported.")
        case .inferenceFailed:
            return AgentBridgeError(code: .transcriptionFailed, message: "The local recognizer could not process this recording.", isRetryable: true)
        case .cancelled:
            return AgentBridgeError(code: .cancelled, message: "Transcription was cancelled.", isRetryable: true)
        }
    }
}

private final class AgentRequestActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let onChange: AgentTranscriptionBroker.BusyHandler
    private var count = 0
    private var usedEngine = false

    init(onChange: @escaping AgentTranscriptionBroker.BusyHandler) {
        self.onChange = onChange
    }

    func begin() {
        let changed = lock.withLock { () -> Bool in
            count += 1
            return count == 1
        }
        if changed { onChange(true, false) }
    }

    func markEngineUse() {
        lock.withLock { usedEngine = true }
    }

    func end() {
        let completed = lock.withLock { () -> Bool? in
            count = max(0, count - 1)
            guard count == 0 else { return nil }
            defer { usedEngine = false }
            return usedEngine
        }
        if let completed { onChange(false, completed) }
    }
}

private extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
