import AppKit
import SwiftUI

/// The short, in-context preflight for a screen recording.
///
/// Privacy controls live here because this is the moment the person decided
/// to capture a display. The panel stays a single calm surface: one display row,
/// one source list, and one action. Settings changes never start a recording
/// implicitly; returning to this panel only refreshes the facts.
struct ScreenRecordingSetup: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 18)
                    displaySelection
                        .padding(.bottom, 20)
                    captureControls
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)
            }

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 520, height: 640)
        .glassWindowBackground()
        .task {
            state.refreshScreenRecordingPermissions()
            await state.refreshScreenDisplays()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: "rectangle.inset.filled")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Screen recording")
                    .font(.title3.weight(.semibold))
                Text("Choose what to include.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private var displaySelection: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Display")
                    .font(.body.weight(.medium))
                Text(selectedDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if state.screenDisplays.count > 1 {
                Menu {
                    ForEach(state.screenDisplays) { display in
                        Button {
                            state.screenRecordingOptions.displayID = display.id
                        } label: {
                            if display.id == state.screenRecordingOptions.displayID {
                                Label(display.name, systemImage: "checkmark")
                            } else {
                                Text(display.name)
                            }
                        }
                    }
                } label: {
                    Label("Change", systemImage: "chevron.up.chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentSurface(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Display: \(selectedDisplayName)")
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Include")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                CaptureOptionRow(
                    title: "Camera",
                    subtitle: cameraSubtitle,
                    symbol: "video.fill",
                    isOn: cameraBinding,
                    isDisabled: false
                ) {
                    state.refreshScreenRecordingPermissions()
                }
                CaptureOptionRow(
                    title: "Microphone",
                    subtitle: microphoneSubtitle,
                    symbol: "mic.fill",
                    isOn: $state.screenRecordingOptions.microphoneEnabled,
                    isDisabled: false
                ) {
                    state.refreshScreenRecordingPermissions()
                }
                CaptureOptionRow(
                    title: "Mac audio",
                    subtitle: state.systemAudioMode == .unsupported ? "Unavailable on this Mac" : "System sound",
                    symbol: "speaker.wave.2.fill",
                    isOn: $state.screenRecordingOptions.systemAudioEnabled,
                    isDisabled: state.systemAudioMode == .unsupported
                )
            }
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if state.screenRecordingOptions.cameraEnabled {
                ScreenCameraPreview(
                    cameraAvailable: state.screenCameraPermission == .granted,
                    bubbleScale: state.screenRecordingOptions.bubbleScale,
                    bubblePosition: state.screenRecordingOptions.bubblePosition,
                    onPositionChanged: state.setRecordingBubblePosition
                )
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .padding(.top, 2)

                HStack(spacing: 10) {
                    Text("Smaller")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $state.screenRecordingOptions.bubbleScale, in: 0.12...0.34)
                        .accessibilityLabel("Camera bubble size")
                    Text("Larger")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let issue = permissionIssue {
                permissionRow(issue)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: GlassTokens.Motion.surfaceChange), value: state.screenRecordingOptions.cameraEnabled)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Cancel") { state.dismissScreenRecordingSetup() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                state.startScreenRecording()
            } label: {
                Label("Record", systemImage: "record.circle.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(StatusColorRole.recording.color)
            .disabled(!canStart)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func permissionMessage(for issue: ScreenRecordingSetupIssue) -> String {
        if issue == .screenPermission && state.screenRecordingRestartRequired {
            return "If access is enabled in Settings and Retry still fails, quit and reopen OpenRamble once."
        }
        return issue.message
    }

    private var selectedDisplayName: String {
        state.screenDisplays.first(where: { $0.id == state.screenRecordingOptions.displayID })?.name
            ?? state.screenDisplays.first?.name
            ?? "Choose a display"
    }

    private var cameraSubtitle: String {
        guard state.screenRecordingOptions.cameraEnabled else { return "Bubble off" }
        switch state.screenCameraPermission {
        case .granted: return "Bubble on"
        case .notDetermined: return "Ask on start"
        case .denied: return "Allow in Settings"
        case .restricted: return "Restricted"
        }
    }

    private var microphoneSubtitle: String {
        guard state.screenRecordingOptions.microphoneEnabled else { return "Voice off" }
        switch state.screenMicrophonePermission {
        case .granted: return "Your voice"
        case .notDetermined: return "Ask on start"
        case .denied: return "Allow in Settings"
        case .restricted: return "Restricted"
        }
    }

    private var permissionIssue: ScreenRecordingSetupIssue? {
        guard !state.isLoadingScreenDisplays else { return nil }
        if state.screenDisplays.isEmpty {
            return state.screenSetupIssue ?? .noDisplay
        }
        if state.screenRecordingOptions.cameraEnabled {
            switch state.screenCameraPermission {
            case .denied: return .cameraPermission
            case .restricted: return .cameraRestricted
            case .granted, .notDetermined: break
            }
        }
        if state.screenRecordingOptions.microphoneEnabled {
            switch state.screenMicrophonePermission {
            case .denied, .restricted: return .microphonePermission
            case .granted, .notDetermined: break
            }
        }
        return nil
    }

    private var canStart: Bool {
        guard !state.isLoadingScreenDisplays, !state.screenDisplays.isEmpty else { return false }
        if state.screenRecordingOptions.cameraEnabled,
           state.screenCameraPermission == .denied || state.screenCameraPermission == .restricted {
            return false
        }
        if state.screenRecordingOptions.microphoneEnabled,
           state.screenMicrophonePermission == .denied || state.screenMicrophonePermission == .restricted {
            return false
        }
        return true
    }

    private func permissionRow(_ issue: ScreenRecordingSetupIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: GlassTokens.Space.inline) {
                Image(systemName: issue.symbol)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(.caption.weight(.semibold))
                    Text(permissionMessage(for: issue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: GlassTokens.Space.inline)
            }
            HStack(spacing: 8) {
                if issue.settingsTitle != nil {
                    Button("Settings") { openSettings(for: issue) }
                        .controlSize(.small)
                }
                if issue == .screenPermission && state.screenRecordingRestartRequired {
                    Button("Restart") { state.relaunchForScreenRecording() }
                        .controlSize(.small)
                }
                Button("Retry") { state.retryScreenRecordingSetup() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .contentSurface(RoundedRectangle(cornerRadius: GlassTokens.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func openSettings(for issue: ScreenRecordingSetupIssue) {
        switch issue {
        case .screenPermission: state.openScreenRecordingSettings()
        case .cameraPermission, .cameraRestricted: state.openCameraSettings()
        case .microphonePermission: state.openMicrophoneSettings()
        case .noDisplay, .captureFailed: break
        }
    }

    private var cameraBinding: Binding<Bool> {
        Binding(
            get: { state.screenRecordingOptions.cameraEnabled },
            set: { enabled in
                state.screenRecordingOptions.cameraEnabled = enabled
                if enabled { state.requestScreenCameraAccessForPreview() }
                state.refreshScreenRecordingPermissions()
            }
        )
    }
}

private struct CaptureOptionRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool
    var isDisabled = false
    var onChange: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: isOn) { _, _ in onChange?() }
                .disabled(isDisabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .opacity(isDisabled ? 0.48 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isDisabled ? "Unavailable" : (isOn ? "On" : "Off"))
    }
}

/// A compatibility spelling for call sites that prefer the explicit suffix.
typealias ScreenRecordingSetupView = ScreenRecordingSetup
