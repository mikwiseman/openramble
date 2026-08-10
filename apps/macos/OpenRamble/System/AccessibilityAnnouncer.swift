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
}
