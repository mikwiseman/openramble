import AppKit

/// Who says out loud what is drawn on the screen.
///
/// Behind the protocol - because the real ad goes to VoiceOver, and his to
/// no check. Without substitution, it is impossible to check a single advertisement, namely
/// they are the entire application interface for a blind person.
@MainActor
public protocol AccessibilityAnnouncing: AnyObject {
    /// Say it out loud. `urgent` - interrupt what is being read now.
    func announce(_ message: String, urgent: Bool)
    /// The microphone just opened. A short tone, never words: anything spoken
    /// now plays into that microphone, and a spoken "Recording." was measured
    /// at the start of 100% of transcripts.
    func playCue()
}

@MainActor
public final class SystemAccessibilityAnnouncer: AccessibilityAnnouncing {
    public init() {}

    public func announce(_ message: String, urgent: Bool) {
        // The announcement is addressed to the application, not the dictation panel. Panel
        // does not intentionally take away focus - otherwise text insertion would break -
        // and VoiceOver skips an announcement from an element outside the focus chain.
        let priority = urgent
            ? NSAccessibilityPriorityLevel.high
            : NSAccessibilityPriorityLevel.medium

        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }

    public func playCue() {
        // VoiceOver users only: they cannot see the panel, and this tone is
        // what replaced the spoken cue they got before. Everyone else has the
        // red dot, and "one sound" stays true for them.
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSSound(named: "Tink")?.play()
    }
}
