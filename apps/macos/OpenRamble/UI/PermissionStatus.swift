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
        explicitActionTitle = granted ? nil : L10n.tr("Grant")
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
                title: L10n.tr("Accessibility"),
                detail: detail,
                granted: false,
                value: L10n.tr("Permission not granted"),
                actionTitle: L10n.tr("Grant")
            )
        case .waitingForSettings:
            return .init(
                title: L10n.tr("Accessibility"),
                detail: L10n.tr("Turn on OpenRamble in the System Settings window that just opened, then come back here."),
                granted: false,
                value: L10n.tr("Waiting for permission in System Settings"),
                actionTitle: L10n.tr("Open System Settings")
            )
        case .restartRequired:
            return .init(
                title: L10n.tr("Accessibility"),
                detail: L10n.tr("If OpenRamble is already turned on, relaunch the app so macOS applies the access to the new process."),
                granted: false,
                value: L10n.tr("App relaunch required"),
                actionTitle: L10n.tr("Relaunch")
            )
        case .repairRequired:
            return .init(
                title: L10n.tr("Accessibility"),
                detail: L10n.tr("macOS keeps an old or duplicate entry for OpenRamble. Remove just that entry and grant access again."),
                granted: false,
                value: L10n.tr("The system permission entry needs repair"),
                actionTitle: L10n.tr("Repair")
            )
        case .repairing:
            return .init(
                title: L10n.tr("Accessibility"),
                detail: L10n.tr("Removing the old entry and relaunching OpenRamble."),
                granted: false,
                value: L10n.tr("Repairing the permission"),
                actionTitle: nil
            )
        case let .failed(message):
            return .init(
                title: L10n.tr("Accessibility"),
                detail: L10n.tr("Repair failed: %@", String(describing: message)),
                granted: false,
                value: L10n.tr("Permission repair failed"),
                actionTitle: L10n.tr("Repair")
            )
        case .granted:
            return .init(
                title: L10n.tr("Accessibility"),
                detail: detail,
                granted: true,
                value: L10n.tr("Permission granted"),
                actionTitle: nil
            )
        }
    }

    /// The permission macOS calls System Audio Recording, for the other side
    /// of a call. There is no API to ask whether it was granted; the app
    /// learns by trying, so the value here is what the last recording found,
    /// never a guess.
    static func systemAudio(mode: SystemAudioPermissionMode) -> PermissionStatus {
        let detail = L10n.tr("Lets OpenRamble record the other people in a call. Used only while you are recording.")
        switch mode {
        case .unsupported:
            return .init(
                title: L10n.tr("System Audio"),
                detail: L10n.tr("Recording what you hear needs macOS 14.2 or later. Dictation and voice notes are unaffected."),
                granted: false,
                value: L10n.tr("Not available on this macOS"),
                actionTitle: nil
            )
        case .declined:
            return .init(
                title: L10n.tr("System Audio"),
                detail: L10n.tr("System audio is off. Recordings include your voice only until you turn it on."),
                granted: false,
                value: L10n.tr("Turned off"),
                actionTitle: L10n.tr("Turn On")
            )
        case .notChecked:
            return .init(
                title: L10n.tr("System Audio"),
                detail: detail + L10n.tr(" macOS asks the first time you record."),
                granted: false,
                value: L10n.tr("Not checked yet"),
                actionTitle: nil
            )
        case .working:
            return .init(title: L10n.tr("System Audio"), detail: detail, granted: true, value: L10n.tr("Working"), actionTitle: nil)
        case .unheard:
            return .init(
                title: L10n.tr("System Audio"),
                detail: L10n.tr("The last recording heard nothing from what this Mac plays. Allow OpenRamble under Screen & System Audio Recording, then relaunch the app."),
                granted: false,
                value: L10n.tr("No sound arrived last time"),
                actionTitle: L10n.tr("Open System Settings")
            )
        }
    }

    /// The title and explanation are about the same thing and are read together.
    var accessibilityLabel: String { "\(title). \(detail)" }

    /// Tick with words: the picture itself doesn't tell VoiceOver anything.
    var accessibilityValue: String {
        explicitValue ?? (granted ? L10n.tr("Permission granted") : L10n.tr("Permission not granted"))
    }

    /// The button is only available where there is still something to output.
    var actionTitle: String? { explicitActionTitle }

    var actionAccessibilityLabel: String? {
        actionTitle.map { action in
            action == L10n.tr("Grant") ? L10n.tr("Grant access: %@", String(describing: title)) : "\(action): \(title)"
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
