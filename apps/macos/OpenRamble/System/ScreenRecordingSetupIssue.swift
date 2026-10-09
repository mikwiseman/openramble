import AVFoundation
import Foundation
import ScreenCaptureKit

/// Recovery belongs in the recorder panel. A camera denial must never look
/// like a screen permission error, and permission errors must not leak TCC's
/// implementation language into the UI.
public enum ScreenRecordingSetupIssue: Equatable, Sendable {
    case screenPermission
    case cameraPermission
    case cameraRestricted
    case microphonePermission
    case noDisplay
    case captureFailed

    var title: String {
        switch self {
        case .screenPermission: return L10n.tr("Allow screen recording")
        case .cameraPermission: return L10n.tr("Allow camera access")
        case .cameraRestricted: return L10n.tr("Camera access is restricted")
        case .microphonePermission: return L10n.tr("Allow microphone access")
        case .noDisplay: return L10n.tr("No display available")
        case .captureFailed: return L10n.tr("Recording couldn't start")
        }
    }

    var message: String {
        switch self {
        case .screenPermission:
            return L10n.tr("Enable OpenRamble in Screen & System Audio Recording. Return here to check again.")
        case .cameraPermission:
            return L10n.tr("Enable OpenRamble in Camera settings, or turn off the camera bubble.")
        case .cameraRestricted:
            return L10n.tr("This Mac restricts camera access. Turn off the bubble to record your screen.")
        case .microphonePermission:
            return L10n.tr("Enable OpenRamble in Microphone settings, or turn off the microphone.")
        case .noDisplay:
            return L10n.tr("Connect a display, then try again.")
        case .captureFailed:
            return L10n.tr("Check that your display and selected devices are available, then try again.")
        }
    }

    var settingsTitle: String? {
        switch self {
        case .screenPermission: return L10n.tr("Screen Recording Settings")
        case .cameraPermission: return L10n.tr("Camera Settings")
        case .microphonePermission: return L10n.tr("Microphone Settings")
        case .cameraRestricted, .noDisplay, .captureFailed: return nil
        }
    }

    /// A screen grant is the only capture permission that can be accepted in
    /// Settings while the running process still has a stale TCC session. The
    /// panel uses this to offer a single explicit relaunch after a failed
    /// retry. It is a recovery option, not proof that the switch is enabled.
    var canRequireRelaunch: Bool {
        self == .screenPermission
    }

    var symbol: String {
        switch self {
        case .screenPermission: return "rectangle.inset.filled.badge.record"
        case .cameraPermission, .cameraRestricted: return "video.fill"
        case .microphonePermission: return "mic.fill"
        case .noDisplay: return "display"
        case .captureFailed: return "exclamationmark.triangle.fill"
        }
    }

    static func from(_ error: Error) -> Self {
        if let captureError = error as? ScreenRecordingError {
            switch captureError {
            case .permissionDenied: return .cameraPermission
            case .cameraRestricted: return .cameraRestricted
            case .noDisplay: return .noDisplay
            default: return .captureFailed
            }
        }
        let error = error as NSError
        if error.domain == AVFoundationErrorDomain,
           error.code == AVError.Code.applicationIsNotAuthorizedToUseDevice.rawValue {
            return .cameraPermission
        }
        if error.domain == SCStreamErrorDomain {
            // These are the public ScreenCaptureKit failure codes. Do not
            // classify arbitrary NSError text as a privacy error: a writer,
            // display, or driver failure must remain actionable as itself.
            switch error.code {
            case -3801, -3803: // userDeclined, missingEntitlements
                return .screenPermission
            case -3814, -3815: // noDisplayList, noCaptureSource
                return .noDisplay
            default:
                break
            }
        }
        return .captureFailed
    }
}
