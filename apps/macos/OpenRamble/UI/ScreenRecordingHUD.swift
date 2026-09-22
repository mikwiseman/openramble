import AppKit
import SwiftUI

/// A non-activating transport that stays reachable while another app is in
/// front. It is intentionally separate from the camera bubble: controls and
/// the face should never become one draggable object.
@MainActor
final class ScreenRecordingHUD {
    private var panel: NSPanel?
    private weak var state: AppState?

    func show(state: AppState, displayID: UInt32?) {
        self.state = state
        if panel == nil { panel = makePanel() }
        position(displayID: displayID)
        panel?.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 292, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ScreenRecordingHUDView(state: state!))
        return panel
    }

    private func position(displayID: UInt32?) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { screen in
            guard let displayID else { return screen == NSScreen.main }
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.minY + 28
            )
        )
    }
}

private struct ScreenRecordingHUDView: View {
    @ObservedObject var state: AppState

    private var isPaused: Bool { state.meetingState == .paused }

    var body: some View {
        HStack(spacing: GlassTokens.Space.inline) {
            Circle()
                .fill(isPaused ? Color.secondary : StatusColorRole.recording.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(isPaused ? "Paused" : "Recording screen")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(RecordingTime.clock(state.liveDuration))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer(minLength: GlassTokens.Space.tight)
            if state.screenRecordingOptions.cameraEnabled {
                Button {
                    state.setRecordingCameraEnabled(false)
                } label: {
                    Image(systemName: "video.fill")
                }
                .help("Hide camera bubble")
                .accessibilityLabel("Hide camera bubble")
                .disabled(state.isCameraChanging)
            } else {
                Button {
                    state.setRecordingCameraEnabled(true)
                } label: {
                    Image(systemName: "video.slash")
                }
                .help("Show camera bubble")
                .accessibilityLabel("Show camera bubble")
                .disabled(state.isCameraChanging)
            }
            Menu {
                Slider(
                    value: Binding(
                        get: { state.screenRecordingOptions.bubbleScale },
                        set: { state.setRecordingBubbleScale($0) }
                    ),
                    in: 0.12...0.36
                )
                .labelsHidden()
                Text("Bubble size")
            } label: {
                Image(systemName: "circle.dashed")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Camera bubble size")
            .accessibilityLabel("Camera bubble size")
            Button {
                if isPaused { state.resumeRecording() } else { state.pauseRecording() }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
            }
            .help(isPaused ? "Resume recording" : "Pause recording")
            .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
            Button {
                state.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(StatusColorRole.recording.color, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop recording")
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, GlassTokens.Space.stack)
        .padding(.vertical, GlassTokens.Space.inline)
        .frame(width: 292)
        .glassSurface(Capsule())
        .accessibilityElement(children: .contain)
    }
}
