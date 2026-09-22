import AVFoundation
import Foundation

/// The only media-asset boundary in OpenRamble.
///
/// Recordings are private files owned by the app. Keeping the check here means
/// a future player cannot accidentally turn a file URL into a network loader,
/// and gives the source-level privacy gate one explicit place to allow.
enum LocalRecordingAsset {
    enum Failure: Error {
        case notAFile
        case missing
    }

    static func make(url: URL) throws -> AVURLAsset {
        guard url.isFileURL, url.scheme == "file", url.host == nil else {
            throw Failure.notAFile
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.missing
        }
        return AVURLAsset(
            url: url,
            options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                AVURLAssetPreferPreciseDurationAndTimingKey: true,
            ]
        )
    }
}
