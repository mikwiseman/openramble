import Foundation

/// The private protocol between the application and its one ASR child.
///
/// There is deliberately no socket address or discovery mechanism: the two
/// pipe descriptors inherited at launch are the entire authority boundary.
public enum ASRWorkerProtocol {
    public static let version: UInt16 = 1
    public static let sampleRate = 16_000
    public static let maximumSamples = 5 * 60 * sampleRate
    public static let maximumPCMBytes = maximumSamples * MemoryLayout<Float>.size
    public static let maximumMetadataBytes = 4 * 1_024 * 1_024
    public static let maximumTranscriptUTF8Bytes = 1 * 1_024 * 1_024
    public static let maximumResultWords = 50_000
    public static let maximumWordUTF8Bytes = 16 * 1_024
}

public enum ASRWireKind: UInt16, Sendable {
    case hello = 1
    case helloAcknowledged = 2
    case prepareMain = 3
    case prepareVocabulary = 4
    case warmInference = 5
    case transcribeSamples = 6
    case transcribeFile = 7
    case acknowledged = 8
    case result = 9
    case failure = 10
    case shutdown = 11
}

public struct ASRWorkerHello: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let parentProcessIdentifier: Int32
    public let appBuild: String

    public init(protocolVersion: UInt16, parentProcessIdentifier: Int32, appBuild: String) {
        self.protocolVersion = protocolVersion
        self.parentProcessIdentifier = parentProcessIdentifier
        self.appBuild = appBuild
    }
}

public struct ASRWorkerHelloAcknowledgement: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let workerProcessIdentifier: Int32

    public init(protocolVersion: UInt16, workerProcessIdentifier: Int32) {
        self.protocolVersion = protocolVersion
        self.workerProcessIdentifier = workerProcessIdentifier
    }
}

public struct ASRWorkerPrepareMain: Codable, Equatable, Sendable {
    public let modelDirectory: String

    public init(modelDirectory: String) {
        self.modelDirectory = modelDirectory
    }
}

public struct ASRWorkerVocabulary: Codable, Equatable, Sendable {
    public struct Term: Codable, Equatable, Sendable {
        public let text: String
        public let aliases: [String]

        public init(text: String, aliases: [String]) {
            self.text = text
            self.aliases = aliases
        }
    }

    public let modelDirectory: String
    public let revision: UInt64
    public let terms: [Term]
    public let minimumSimilarity: Float
    public let biasWeight: Float

    public init(
        modelDirectory: String,
        revision: UInt64,
        terms: [Term],
        minimumSimilarity: Float,
        biasWeight: Float
    ) {
        self.modelDirectory = modelDirectory
        self.revision = revision
        self.terms = terms
        self.minimumSimilarity = minimumSimilarity
        self.biasWeight = biasWeight
    }
}

public struct ASRWorkerTranscribeSamples: Codable, Equatable, Sendable {
    public let sampleRate: Int
    public let sampleCount: Int
    public let languageHint: String?

    public init(sampleRate: Int, sampleCount: Int, languageHint: String?) {
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.languageHint = languageHint
    }
}

public struct ASRWorkerTranscribeFile: Codable, Equatable, Sendable {
    public let path: String
    public let languageHint: String?

    public init(path: String, languageHint: String?) {
        self.path = path
        self.languageHint = languageHint
    }
}

public struct ASRWorkerAcknowledgement: Codable, Equatable, Sendable {
    public let vocabularyRevision: UInt64?

    public init(vocabularyRevision: UInt64? = nil) {
        self.vocabularyRevision = vocabularyRevision
    }
}

public struct ASRWorkerResult: Codable, Equatable, Sendable {
    public struct Word: Codable, Equatable, Sendable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval
        public let confidence: Double?

        public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Double?) {
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
        }
    }

    public let text: String
    public let words: [Word]
    public let audioDuration: TimeInterval
    public let processingDuration: TimeInterval

    public init(
        text: String,
        words: [Word],
        audioDuration: TimeInterval,
        processingDuration: TimeInterval
    ) {
        self.text = text
        self.words = words
        self.audioDuration = audioDuration
        self.processingDuration = processingDuration
    }
}

public enum ASRWorkerFailureCode: String, Codable, Equatable, Sendable {
    case protocolMismatch
    case invalidRequest
    case modelsNotLoaded
    case modelsUnavailable
    case invalidAudio
    case vocabularyInvalid
    case inferenceFailed
    case cancelled
    case internalFailure
}

public struct ASRWorkerFailure: Error, Codable, Equatable, Sendable {
    public let code: ASRWorkerFailureCode
    public let message: String
    public let termIndex: Int?

    public init(code: ASRWorkerFailureCode, message: String, termIndex: Int? = nil) {
        self.code = code
        self.message = message
        self.termIndex = termIndex
    }
}

public enum ASRWorkerJSON {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}
