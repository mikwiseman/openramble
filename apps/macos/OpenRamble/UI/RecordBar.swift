import DictationCore
import SwiftUI

/// A single floating transport. It records the microphone and, where this Mac can, what
/// the Mac plays — the other side of a call. There is no mode to choose. A
/// chevron beside it holds one alternative for one recording; the choice is
/// never remembered, which is what makes offering it safe.
///
/// State, both sources, and controls share one glass surface. The primary
/// action stays in the same place as it changes from Record to Stop.
struct RecordBar: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRecording: Bool {
        state.meetingState == .recording || state.meetingState == .paused
    }

    private var isBusy: Bool {
        state.meetingState == .starting || state.meetingState == .stopping
    }

    private var isScreenMode: Bool {
        state.recordingCaptureKind == .screen
    }

    var body: some View {
        HStack(alignment: .center, spacing: GlassTokens.Space.inline) {
            HStack(spacing: GlassTokens.Space.inline) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isScreenMode ? "rectangle.inset.filled" : "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isRecording ? StatusColorRole.recording.color : .secondary)
                        .frame(width: 24, height: 24)
                        .background(.quaternary.opacity(0.55), in: Circle())
                        .accessibilityHidden(true)
                }
                if isRecording {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.meetingState == .paused ? "Paused" : "Recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(RecordingTime.clock(state.liveDuration))
                            .font(.system(size: 19, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(minWidth: 84, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(state.meetingState == .paused ? "Paused" : "Recording")
                    .accessibilityValue(RecordingTime.spoken(state.liveDuration))
                } else {
                    VStack(alignment: .leading, spacing: GlassTokens.Space.tight) {
                        if !isRecording {
                            Picker("Recording type", selection: $state.recordingCaptureKind) {
                                Label("Audio", systemImage: "waveform").tag(RecordingCaptureKind.audio)
                                Label("Screen", systemImage: "rectangle.inset.filled").tag(RecordingCaptureKind.screen)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 132)
                            .accessibilityLabel("Recording type")
                        }
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: GlassTokens.Space.tight)
            if isRecording {
                LiveLevelMeters(
                    levels: state.liveLevels,
                    isPaused: state.meetingState == .paused,
                    showsOthers: state.liveRecording?.isMeeting ?? false,
                    othersDegraded: state.liveCaptureHealth.marksRecordingDegraded,
                    youDegraded: state.liveMicrophoneHealth.marksRecordingDegraded
                )
                Spacer(minLength: GlassTokens.Space.tight)
                Button {
                    if state.meetingState == .paused { state.resumeRecording() } else { state.pauseRecording() }
                } label: {
                    Image(systemName: state.meetingState == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(state.meetingState == .paused ? "Resume recording" : "Pause recording")
                .accessibilityLabel(state.meetingState == .paused ? "Resume recording" : "Pause recording")
            }
            HStack(spacing: 0) {
                Button {
                    if isRecording {
                        state.stopRecording()
                    } else if isScreenMode {
                        state.prepareScreenRecording()
                    } else {
                        state.startRecording()
                    }
                } label: {
                    Label(
                        isRecording ? "Stop" : "Record",
                        systemImage: isRecording ? "stop.fill" : "record.circle"
                    )
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, GlassTokens.Space.stack)
                        .frame(height: 40)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRecording ? "Stop recording" : "Record")
                .accessibilityHint(isRecording ? "Ends the recording and keeps it" : line)
                if !isRecording, let alternative {
                    Menu {
                        Button(alternative.title, action: alternative.action)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 40)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.trailing, 4)
                    .accessibilityLabel("Other ways to record")
                }
            }
            .foregroundStyle(.white)
            .background(StatusColorRole.recording.color, in: Capsule())
            .disabled(isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 760, minHeight: 58)
        .glassSurface(Capsule())
        .animation(reduceMotion ? nil : .easeOut(duration: GlassTokens.Motion.surfaceChange), value: isRecording)
    }

    /// The one alternative, for this recording only.
    private var alternative: (title: String, action: () -> Void)? {
        guard !isScreenMode else { return nil }
        switch state.systemAudioMode {
        case .enabled:
            return ("Record Microphone Only", { state.startRecording(includingSystemAudio: false) })
        case .declined:
            return ("Record You and Others", {
                state.setSystemAudioDeclined(false)
                state.startRecording()
            })
        case .unsupported:
            return nil
        }
    }

    private var line: String {
        switch state.meetingState {
        case .idle:
            if isScreenMode { return "Records this display" }
            return state.systemAudioMode == .enabled ? "Records you and the other side" : "Records your microphone only"
        case .starting: return "Starting…"
        case .recording: return "Recording — \(RecordingTime.clock(state.liveDuration))"
        case .paused: return "Paused — \(RecordingTime.clock(state.liveDuration))"
        case .stopping: return "Saving…"
        }
    }
}
