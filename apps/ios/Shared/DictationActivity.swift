import ActivityKit
import Foundation

/// What the Lock Screen and the Dynamic Island show while a take is recorded
/// and written. Shared by the app, which starts and updates it, and the widget
/// extension, which draws it.
///
/// It never carries the words themselves: the Lock Screen is visible to anyone
/// holding the phone. It says that the words were written and copied.
public struct DictationActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public enum Stage: String, Codable, Hashable, Sendable {
            case listening
            case writing
            case written
            case failed
        }

        public var stage: Stage
        /// When recording began, so the system can count the time itself.
        public var startedAt: Date
        /// Seconds recorded, once recording has stopped.
        public var duration: TimeInterval?
        /// How many words were written.
        public var wordCount: Int?
        /// Whether the words are on the clipboard.
        public var copied: Bool

        public init(stage: Stage, startedAt: Date, duration: TimeInterval? = nil, wordCount: Int? = nil, copied: Bool) {
            self.stage = stage
            self.startedAt = startedAt
            self.duration = duration
            self.wordCount = wordCount
            self.copied = copied
        }
    }

    public init() {}
}
