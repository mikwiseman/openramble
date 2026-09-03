import DictationAudio
import DictationCore
import SwiftUI

/// The recordings, newest first, with the one in progress pinned on top and
/// the record button beneath — never scrolling away.
struct RecordingsList: View {
    @ObservedObject var state: AppState
    @Binding var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                if let live = state.liveRecording {
                    LiveRecordingRow(state: state)
                        .tag(live.id)
                }
                ForEach(state.recordings) { recording in
                    RecordingRow(recording: recording)
                        .tag(recording.id)
                }
            }
            .listStyle(.inset)
            .onDeleteCommand {
                guard let selection, let recording = state.recordings.first(where: { $0.id == selection }) else {
                    return
                }
                state.trashRecording(recording.id)
            }
            Divider()
            RecordBar(state: state)
        }
    }
}

struct RecordingRow: View {
    let recording: MeetingRecordingMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title ?? RecordingsPlaceholder.defaultTitle(for: recording.startedAt))
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: GlassTokens.Space.inline)
                Text(RecordingTime.clock(recording.duration))
                    .font(.system(size: GlassTokens.Label.footnote))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: GlassTokens.Space.tight) {
                Image(systemName: glyph.name)
                    .foregroundStyle(glyph.color)
                    .font(.system(size: GlassTokens.Label.footnote))
                    .accessibilityHidden(true)
                // Untitled, the title already is the date; repeating it here
                // read as a bug. The kind is the other thing worth a glance.
                Text(recording.title == nil
                    ? (recording.isMeeting ? "Meeting" : "Voice note")
                    : recording.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: GlassTokens.Label.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, GlassTokens.Space.tight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recording.title ?? RecordingsPlaceholder.defaultTitle(for: recording.startedAt))
        .accessibilityValue(accessibilityValue)
    }

    /// One glyph, three meanings, and colour never load-bearing on its own.
    private var glyph: (name: String, color: Color) {
        switch recording.endReason {
        case .crashRecovered, .diskFull, .writeFailed:
            return ("exclamationmark.triangle.fill", StatusColorRole.attention.color)
        default:
            return recording.isMeeting ? ("person.2.wave.2", .secondary) : ("mic", .secondary)
        }
    }

    private var accessibilityValue: String {
        var parts = [
            recording.isMeeting ? "Meeting" : "Voice note",
            RecordingTime.spoken(recording.duration),
            recording.startedAt.formatted(date: .abbreviated, time: .shortened),
        ]
        if let note = RecordingsPlaceholder.endNote(for: recording.endReason) { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

/// The recording in progress: red dot, elapsed time, and a level meter that
/// keeps moving as long as the microphone is heard.
struct LiveRecordingRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: GlassTokens.Space.tight) {
                Circle()
                    .fill(state.meetingState == .paused ? Color.secondary : StatusColorRole.recording.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(state.meetingState == .paused ? "Paused" : "Recording")
                    .font(.body.weight(.medium))
                Spacer(minLength: GlassTokens.Space.inline)
                Text(RecordingTime.clock(state.liveDuration))
                    .font(.system(size: GlassTokens.Label.footnote))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LiveLevelMeter(levels: state.liveLevels, isPaused: state.meetingState == .paused)
                .frame(height: 20)
        }
        .padding(.vertical, GlassTokens.Space.tight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.meetingState == .paused ? "Recording, paused" : "Recording")
        .accessibilityValue(RecordingTime.spoken(state.liveDuration))
    }
}

/// The rolling meter, fed from the recorder's level updates.
///
/// `RecordingWaveform` is reused untouched: it draws silence as a visible
/// 1 pt line rather than an empty box, which is what makes a dead source
/// look dead instead of looking like a layout gap.
struct LiveLevelMeter: View {
    let levels: MeetingCapture.Levels
    let isPaused: Bool
    @State private var samples: [Float] = Array(repeating: 0, count: 24)

    var body: some View {
        RecordingWaveform(
            samples: samples,
            color: isPaused ? .secondary : StatusColorRole.recording.color
        )
        .onChange(of: levels) { _, levels in
            samples.removeFirst()
            samples.append(levels.microphone)
        }
        .accessibilityHidden(true)
    }
}
