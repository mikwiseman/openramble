import Foundation

/// One thing the person said, and what it became.
///
/// The audio is kept beside the text until the person deletes the take, so a
/// word the model misheard can be listened to, and a take that failed to be
/// written can be written again. Nothing about a take is ever dropped silently:
/// a recording whose writing was interrupted comes back as `.writing` on the
/// next launch and is written then.
struct Take: Codable, Identifiable, Equatable, Sendable {
    enum State: Codable, Equatable, Sendable {
        /// Recorded; the words are being written.
        case writing
        /// Written. `text` holds the words.
        case written
        /// The recording held no speech. Kept, so the person sees it happened.
        case silent
        /// Writing failed. The audio is kept, and writing can be tried again.
        case failed(String)
    }

    let id: UUID
    let recordedAt: Date
    var duration: TimeInterval
    var text: String
    var state: State
    /// The audio's file name inside the store's audio folder, if it is kept.
    var audioFileName: String?
    /// Where the take came from: the microphone, or a file the person opened.
    var source: Source
    /// Seconds from the end of the recording to the words: what the person
    /// waited.
    var writtenIn: TimeInterval?

    enum Source: String, Codable, Sendable {
        case microphone
        case file
    }

    init(
        id: UUID = UUID(),
        recordedAt: Date = .now,
        duration: TimeInterval,
        text: String = "",
        state: State = .writing,
        audioFileName: String? = nil,
        source: Source = .microphone
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.duration = duration
        self.text = text
        self.state = state
        self.audioFileName = audioFileName
        self.source = source
    }

    var hasWords: Bool {
        state == .written && !text.isEmpty
    }
}
