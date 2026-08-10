import Foundation

/// How often to request permissions.
///
/// Permissions are granted and revoked in the system settings, the application does not know about this
/// they report - you have to ask the status yourself.
///
/// There was a temptation to slow down the polling when everything was given out: the application lives in the line
/// menu for weeks, and a second timer all this time - millions of awakenings for the sake of
/// response that changes once. This was deliberately abandoned. Review
/// access does not send a reliable event, and the application with the revoked
/// Accessibility looks intact and silently does not work - icon in menu bar
/// must say this no later than two seconds, including from complete peace.
/// While the safe beta is ongoing, the integrity of the icon is more valuable than the saved awakenings.
///
/// Hence the type of function: issued permissions do not affect the interval, and
/// The only way to turn off polling is to set the `base` to zero externally.
/// It will be possible to return the slowdown when a reliable notification appears
/// about the review - but not before.
enum PermissionPollPolicy {
    /// Returns the interval between polls. Zero - do not poll.
    static func interval(
        accessibilityGranted: Bool,
        microphoneGranted: Bool,
        base: TimeInterval
    ) -> TimeInterval {
        // Zero means "polling is turned off externally" - that's what tests do.
        guard base > 0 else { return 0 }

        // Both flags are deliberately not used: see the solution in the type header. They
        // remain in the signature because they are the ones that will be returned to the calculation when
        // the review will have a reliable notification.
        _ = accessibilityGranted
        _ = microphoneGranted
        return min(base, 2)
    }
}
