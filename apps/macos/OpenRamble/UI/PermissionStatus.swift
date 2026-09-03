/// Permission line - the same in onboarding and settings.
///
/// Both buttons on the screen are called “Issue”, and they are indistinguishable by ear: without
/// permission name, a blind person hears two identical buttons and does not know
/// which one is which.
struct PermissionStatus: Equatable {
    let title: String
    let detail: String
    let granted: Bool
    private let explicitValue: String?
    private let explicitActionTitle: String?

    init(title: String, detail: String, granted: Bool) {
        self.title = title
        self.detail = detail
        self.granted = granted
        explicitValue = nil
        explicitActionTitle = granted ? nil : "Grant"
    }

    private init(
        title: String,
        detail: String,
        granted: Bool,
        value: String,
        actionTitle: String?
    ) {
        self.title = title
        self.detail = detail
        self.granted = granted
        explicitValue = value
        explicitActionTitle = actionTitle
    }

    static func accessibility(
        state: AccessibilityPermissionState,
        detail: String
    ) -> PermissionStatus {
        switch state {
        case .denied:
            return .init(
                title: "Accessibility",
                detail: detail,
                granted: false,
                value: "Permission not granted",
                actionTitle: "Grant"
            )
        case .waitingForSettings:
            return .init(
                title: "Accessibility",
                detail: "Turn on OpenRamble in the System Settings window that just opened, then come back here.",
                granted: false,
                value: "Waiting for permission in System Settings",
                actionTitle: "Open System Settings"
            )
        case .restartRequired:
            return .init(
                title: "Accessibility",
                detail: "If OpenRamble is already turned on, relaunch the app so macOS applies the access to the new process.",
                granted: false,
                value: "App relaunch required",
                actionTitle: "Relaunch"
            )
        case .repairRequired:
            return .init(
                title: "Accessibility",
                detail: "macOS keeps an old or duplicate entry for OpenRamble. Remove just that entry and grant access again.",
                granted: false,
                value: "The system permission entry needs repair",
                actionTitle: "Repair"
            )
        case .repairing:
            return .init(
                title: "Accessibility",
                detail: "Removing the old entry and relaunching OpenRamble.",
                granted: false,
                value: "Repairing the permission",
                actionTitle: nil
            )
        case let .failed(message):
            return .init(
                title: "Accessibility",
                detail: "Repair failed: \(message)",
                granted: false,
                value: "Permission repair failed",
                actionTitle: "Repair"
            )
        case .granted:
            return .init(
                title: "Accessibility",
                detail: detail,
                granted: true,
                value: "Permission granted",
                actionTitle: nil
            )
        }
    }

    /// The permission macOS calls System Audio Recording, for the other side
    /// of a call. There is no API to ask whether it was granted; the app
    /// learns by trying, so the value here is what the last recording found,
    /// never a guess.
    static func systemAudio(mode: SystemAudioPermissionMode) -> PermissionStatus {
        let detail = "Lets OpenRamble record the other people in a call. Used only while you are recording."
        switch mode {
        case .unsupported:
            return .init(
                title: "System Audio",
                detail: "Recording what you hear needs macOS 14.2 or later. Dictation and voice notes are unaffected.",
                granted: false,
                value: "Not available on this macOS",
                actionTitle: nil
            )
        case .declined:
            return .init(
                title: "System Audio",
                detail: "You chose to record your microphone only. Recordings will not include the other side of a call.",
                granted: false,
                value: "Turned off",
                actionTitle: "Turn On"
            )
        case .notChecked:
            return .init(
                title: "System Audio",
                detail: detail + " macOS asks the first time you record.",
                granted: false,
                value: "Not checked yet",
                actionTitle: nil
            )
        case .working:
            return .init(title: "System Audio", detail: detail, granted: true, value: "Working", actionTitle: nil)
        case .unheard:
            return .init(
                title: "System Audio",
                detail: "The last recording heard nothing from what this Mac plays. Allow OpenRamble under Screen & System Audio Recording, then relaunch the app.",
                granted: false,
                value: "No sound arrived last time",
                actionTitle: "Open System Settings"
            )
        }
    }

    /// The title and explanation are about the same thing and are read together.
    var accessibilityLabel: String { "\(title). \(detail)" }

    /// Tick with words: the picture itself doesn't tell VoiceOver anything.
    var accessibilityValue: String {
        explicitValue ?? (granted ? "Permission granted" : "Permission not granted")
    }

    /// The button is only available where there is still something to output.
    var actionTitle: String? { explicitActionTitle }

    var actionAccessibilityLabel: String? {
        actionTitle.map { action in
            action == "Grant" ? "Grant access: \(title)" : "\(action): \(title)"
        }
    }
}

/// What the app knows about the System Audio Recording permission.
enum SystemAudioPermissionMode: Equatable {
    case unsupported
    case declined
    case notChecked
    case working
    case unheard
}
