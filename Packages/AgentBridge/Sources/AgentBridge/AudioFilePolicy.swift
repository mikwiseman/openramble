import Foundation

public struct ValidatedAudioFile: Equatable, Sendable {
    public let url: URL
    public let byteCount: UInt64
}

public enum AudioFilePolicyError: Error, Equatable, Sendable {
    case pathMustBeAbsolute
    case symbolicLinksNotAllowed
    case notARegularFile
    case unreadable
    case empty
    case tooLarge(actual: UInt64, maximum: UInt64)
}
