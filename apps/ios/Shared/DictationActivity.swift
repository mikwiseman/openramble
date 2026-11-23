import ActivityKit
import Foundation

/// What the Lock Screen and the Dynamic Island show while a take is recorded
/// and written. Shared by the app, which starts and updates it, and the widget
/// extension, which draws it.
///
/// It never carries the words themselves: the Lock Screen is visible to anyone
/// holding the phone. It says that the words were written and copied.
struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Stage: String, Codable, Hashable, Sendable {
            case listening
            case writing
            case written
            case failed
        }

        var stage: Stage
        /// When recording began, so the system can count the time itself.
        var startedAt: Date
        /// Seconds recorded, once recording has stopped.
        var duration: TimeInterval?
        /// How many words were written.
        var wordCount: Int?
        /// Whether the words are on the clipboard.
        var copied: Bool
    }
}
