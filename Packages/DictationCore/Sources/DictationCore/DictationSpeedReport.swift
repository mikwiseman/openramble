import Foundation

/// How long it took from releasing the key to each noticeable point.
///
/// There are three marks, not one, because “fast” are three different promises, and
/// it’s unfair to confuse them:
///
/// - `toRecognizedText` - the engine returned the text;
/// - `toPasteDispatched` - ⌘V sent, that is, the text is already in someone else’s window.
/// **This is the headline metric** and what the HUD shows;
/// - `toClipboardRestored` - the previous contents of the buffer are returned to their place.
///
/// There is no prohibited metric here intentionally: “time until return
/// `TextInserter.insert`" is not a speed - it’s a thousand milliseconds inside
/// buffer protection. It's waiting, not working.
///
/// `nil` means "not measured", and never "zero". The land that can't
/// give a mark, has no right to look instant.
public struct DictationSpeedReport: Sendable, Equatable {
    public let toRecognizedText: Duration
    public let toPasteDispatched: Duration?
    public let toClipboardRestored: Duration?
    /// How long the microphone was raised before the first frame. Does not count from
    /// releases are a warm-up before the phrase, not after it.
    public let microphoneStartup: Duration?

    public init(
        toRecognizedText: Duration,
        toPasteDispatched: Duration? = nil,
        toClipboardRestored: Duration? = nil,
        microphoneStartup: Duration? = nil
    ) {
        self.toRecognizedText = toRecognizedText
        self.toPasteDispatched = toPasteDispatched
        self.toClipboardRestored = toClipboardRestored
        self.microphoneStartup = microphoneStartup
    }
}

/// When the insertion has done something that is visible to humans.
///
/// The inserter himself removes the marks: they cannot be taken from outside, because `insert`
/// returns only after a second of buffer protection.
public struct InsertionMarks: Sendable, Equatable {
    public let pasteDispatchedAt: ContinuousClock.Instant?
    public let clipboardRestoredAt: ContinuousClock.Instant?

    public init(
        pasteDispatchedAt: ContinuousClock.Instant? = nil,
        clipboardRestoredAt: ContinuousClock.Instant? = nil
    ) {
        self.pasteDispatchedAt = pasteDispatchedAt
        self.clipboardRestoredAt = clipboardRestoredAt
    }
}
