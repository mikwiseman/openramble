import Foundation

/// Decoded segments in, readable paragraphs out.
///
/// A segment is where the audio happened to be cut; a paragraph is what a
/// person reads. Same-channel segments merge until something closes the
/// paragraph: the other side speaking (exact, because the channel is the
/// speaker), a pause longer than `gap`, a sentence ending once the paragraph
/// is long enough to read, or a hard length past which any paragraph is a
/// wall. The thresholds are the ones a sibling project measured against real
/// meeting transcripts.
///
/// Gaps are computed from the segments' frame positions, so none of this
/// needs an engine timestamp. Pure.
public struct MeetingUtteranceAssembler: Sendable {
    public struct Parameters: Sendable, Equatable {
        /// A same-channel silence longer than this starts a new paragraph.
        public var gap: TimeInterval
        /// Past this, a sentence ending closes the paragraph.
        public var softDuration: TimeInterval
        /// Past this, anything closes it.
        public var hardDuration: TimeInterval

        public init(gap: TimeInterval = 1.2, softDuration: TimeInterval = 12, hardDuration: TimeInterval = 40) {
            self.gap = gap
            self.softDuration = softDuration
            self.hardDuration = hardDuration
        }
    }

    /// One decoded segment on the recording's timeline.
    public struct Segment: Sendable, Equatable {
        public let channel: MeetingChannel
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
        public let isFailed: Bool

        public init(channel: MeetingChannel, start: TimeInterval, end: TimeInterval, text: String, isFailed: Bool = false) {
            self.channel = channel
            self.start = start
            self.end = end
            self.text = text
            self.isFailed = isFailed
        }
    }

    public let parameters: Parameters
    private var open: MeetingUtterance?

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// Feed one segment; get back whatever paragraphs it closed.
    public mutating func append(_ segment: Segment) -> [MeetingUtterance] {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Silence decodes to nothing. It is not a paragraph and it does not
        // close one — a breath between two sentences is not a topic change.
        guard segment.isFailed || !text.isEmpty else { return [] }

        var closed: [MeetingUtterance] = []
        if let current = open, shouldClose(current, before: segment) {
            closed.append(current)
            open = nil
        }
        if var current = open, !segment.isFailed {
            current.end = max(current.end, segment.end)
            current.text = current.text.isEmpty ? text : current.text + " " + text
            open = current
        } else {
            open = MeetingUtterance(
                channel: segment.channel,
                start: segment.start,
                end: segment.end,
                text: segment.isFailed ? "" : text,
                isFailed: segment.isFailed
            )
            // A failure is its own paragraph, closed at once: nothing merges
            // into a hole in the transcript.
            if segment.isFailed, let failed = open {
                closed.append(failed)
                open = nil
            }
        }
        return closed
    }

    /// The paragraph in progress — shown live, closed by whatever comes next.
    public var pending: MeetingUtterance? { open }

    /// The paragraph still open, at the end.
    public mutating func flush() -> [MeetingUtterance] {
        defer { open = nil }
        return open.map { [$0] } ?? []
    }

    private func shouldClose(_ current: MeetingUtterance, before segment: Segment) -> Bool {
        if current.isFailed || segment.isFailed { return true }
        if segment.channel != current.channel { return true }
        if segment.start - current.end > parameters.gap { return true }
        let duration = current.end - current.start
        if duration >= parameters.hardDuration { return true }
        if duration >= parameters.softDuration, Self.endsSentence(current.text) { return true }
        return false
    }

    /// Ends in `.`, `!`, `?` or `…`, allowing a closing quote or bracket after.
    static func endsSentence(_ text: String) -> Bool {
        var scalars = text.unicodeScalars.reversed().makeIterator()
        var last = scalars.next()
        while let scalar = last, "\"'»)]”’".unicodeScalars.contains(scalar) {
            last = scalars.next()
        }
        guard let terminal = last else { return false }
        return ".!?…".unicodeScalars.contains(terminal)
    }
}
