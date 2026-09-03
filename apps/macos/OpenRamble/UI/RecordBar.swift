import SwiftUI

/// One red button. It records the microphone; there is no mode to choose.
///
/// While recording, the circle becomes a square: the same button, the
/// opposite verb. The line beneath is not a control — it says what the
/// button will do, or what it is doing, in words.
struct RecordBar: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRecording: Bool {
        state.meetingState == .recording || state.meetingState == .paused
    }

    private var isBusy: Bool {
        state.meetingState == .starting || state.meetingState == .stopping
    }

    var body: some View {
        VStack(spacing: GlassTokens.Space.inline) {
            HStack(spacing: GlassTokens.Space.stack) {
                if isRecording {
                    Button {
                        if state.meetingState == .paused { state.resumeRecording() } else { state.pauseRecording() }
                    } label: {
                        Image(systemName: state.meetingState == .paused ? "play.fill" : "pause.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderless)
                    .glassControl()
                    .accessibilityLabel(state.meetingState == .paused ? "Resume recording" : "Pause recording")
                    .transition(.opacity)
                }

                Button {
                    if isRecording { state.stopRecording() } else { state.startRecording() }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.18), lineWidth: 2)
                            .frame(width: 58, height: 58)
                        RoundedRectangle(cornerRadius: isRecording ? 5 : 26, style: .continuous)
                            .fill(StatusColorRole.recording.color)
                            .frame(width: isRecording ? 22 : 52, height: isRecording ? 22 : 52)
                            .animation(reduceMotion ? nil : .easeOut(duration: GlassTokens.Motion.controlFeedback), value: isRecording)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel(isRecording ? "Stop recording" : "Record")
                .accessibilityHint(isRecording ? "Ends the recording and keeps it" : "Records your microphone until you stop")
                .keyboardShortcut("r", modifiers: .command)

                if isRecording {
                    // Keeps the red button centred while the pause control is
                    // shown on its left.
                    Color.clear.frame(width: 36, height: 36)
                }
            }
            Text(line)
                .font(.system(size: GlassTokens.Label.footnote))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, GlassTokens.Space.stack)
    }

    private var line: String {
        switch state.meetingState {
        case .idle: return "Records your microphone"
        case .starting: return "Starting…"
        case .recording: return "Recording — \(RecordingTime.clock(state.liveDuration))"
        case .paused: return "Paused — \(RecordingTime.clock(state.liveDuration))"
        case .stopping: return "Saving…"
        }
    }
}
