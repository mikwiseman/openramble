import Foundation

public enum AgentBridgeProtocol {
    public static let version = 1
    public static let accessPreferenceKey = "agentTranscriptionEnabled"
    public static let defaultMaximumFrameBytes = 4 * 1_024 * 1_024
    public static let defaultMaximumFileBytes: UInt64 = 1_024 * 1_024 * 1_024
    public static let defaultMaximumAudioSeconds: TimeInterval = 30 * 60
}

public struct AgentTranscriptionRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    /// A server-staging-directory basename, never an arbitrary user path.
    /// The helper copies or clones the source before crossing the process
    /// boundary so the app does not need access to privacy-protected folders.
    public let stagedFileName: String
    public let languageHint: String?
    public let includesTimestamps: Bool

    public init(
        protocolVersion: Int = AgentBridgeProtocol.version,
        requestID: UUID = UUID(),
        stagedFileName: String,
        languageHint: String? = nil,
        includesTimestamps: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.stagedFileName = stagedFileName
        self.languageHint = languageHint
        self.includesTimestamps = includesTimestamps
    }
}

public struct AgentTranscriptionWord: Codable, Equatable, Sendable {
    public let text: String
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let confidence: Double?

    public init(
        text: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        confidence: Double?
    ) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
    }
}

public struct AgentTranscriptionResult: Codable, Equatable, Sendable {
    public let text: String
    public let audioDurationSeconds: TimeInterval
    public let processingDurationSeconds: TimeInterval
    public let queueWaitSeconds: TimeInterval
    public let totalDurationSeconds: TimeInterval
    public let languageHint: String?
    public let words: [AgentTranscriptionWord]?

    public init(
        text: String,
        audioDurationSeconds: TimeInterval,
        processingDurationSeconds: TimeInterval,
        queueWaitSeconds: TimeInterval,
        totalDurationSeconds: TimeInterval,
        languageHint: String?,
        words: [AgentTranscriptionWord]?
    ) {
        self.text = text
        self.audioDurationSeconds = audioDurationSeconds
        self.processingDurationSeconds = processingDurationSeconds
        self.queueWaitSeconds = queueWaitSeconds
        self.totalDurationSeconds = totalDurationSeconds
        self.languageHint = languageHint
        self.words = words
    }
}

public struct AgentBridgeError: Error, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case accessDisabled = "access_disabled"
        case appUnavailable = "app_unavailable"
        case audioTooLong = "audio_too_long"
        case busy
        case cancelled
        case engineLoading = "engine_loading"
        case engineRecycled = "engine_recycled"
        case fileTooLarge = "file_too_large"
        case fileUnreadable = "file_unreadable"
        case invalidAudio = "invalid_audio"
        case invalidLanguage = "invalid_language"
        case invalidPath = "invalid_path"
        case modelCorrupt = "model_corrupt"
        case modelNotInstalled = "model_not_installed"
        case preemptedByDictation = "preempted_by_dictation"
        case protocolMismatch = "protocol_mismatch"
        case serverShuttingDown = "server_shutting_down"
        case transcriptionFailed = "transcription_failed"
    }

    public let code: Code
    public let message: String
    public let isRetryable: Bool

    public init(code: Code, message: String, isRetryable: Bool = false) {
        self.code = code
        self.message = message
        self.isRetryable = isRetryable
    }
}

public enum AgentBridgeProgress: String, Codable, Equatable, Sendable {
    case queued
    case waitingForDictation = "waiting_for_dictation"
    case decoding
    case transcribing
}

public enum AgentBridgeClientMessage: Codable, Equatable, Sendable {
    case transcribe(AgentTranscriptionRequest)
    case cancel(requestID: UUID)
}

public enum AgentBridgeServerMessage: Codable, Equatable, Sendable {
    case progress(requestID: UUID, stage: AgentBridgeProgress)
    case result(requestID: UUID, result: AgentTranscriptionResult)
    case failure(requestID: UUID, error: AgentBridgeError)
}
