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
            contentRect: NSRect(x: 0, y: 0, width: ScreenRecordingHUDView.width, height: GlassTokens.Block.unit),
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

/// The screen recording, as the same block a take is: a rim of glass around
/// an opaque slip, one glyph, one word, one clock. Its three controls sit on
/// the slip, so nothing here is written on glass either.
struct ScreenRecordingHUDView: View {
    @ObservedObject var state: AppState

    /// Wide enough for the word, an hour-long clock and three controls, in
    /// either language.
    static let width: CGFloat = 352

    private var isPaused: Bool { state.meetingState == .paused }

    var body: some View {
        HStack(spacing: 8) {
            // Red is the microphone capturing. Paused, it is not.
            StateGlyphView(glyph: isPaused ? .silent : .listening)
            Text(isPaused ? L10n.tr("Paused") : L10n.tr("Recording screen"))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Text(RecordingTime.clock(state.liveDuration))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: GlassTokens.Space.tight)
            if state.screenRecordingOptions.cameraEnabled {
                control("video.fill", L10n.tr("Hide camera bubble")) {
                    state.setRecordingCameraEnabled(false)
                }
                .disabled(state.isCameraChanging)
            } else {
                control("video.slash", L10n.tr("Show camera bubble")) {
                    state.setRecordingCameraEnabled(true)
                }
                .disabled(state.isCameraChanging)
            }
            control(
                isPaused ? "play.fill" : "pause.fill",
                isPaused ? L10n.tr("Resume recording") : L10n.tr("Pause recording")
            ) {
                if isPaused { state.resumeRecording() } else { state.pauseRecording() }
            }
            Button {
                state.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        StatusColorRole.recording.color,
                        in: RoundedRectangle(cornerRadius: GlassTokens.Radius.chip, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Stop recording"))
            .accessibilityLabel(L10n.tr("Stop recording"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(width: Self.width - 2 * GlassTokens.Block.rim, height: GlassTokens.Block.unit - 2 * GlassTokens.Block.rim)
        .wordSlip()
        .glassBlock()
        .accessibilityElement(children: .contain)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: GlassTokens.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}
