import DictationAudio
import DictationCore
import SwiftUI

/// Newest first, grouped by local day. The recording in progress stays pinned above the archive.
struct RecordingsList: View {
    @ObservedObject var state: AppState
    @Binding var selection: Set<UUID>
    let onRename: (UUID, String?) -> Void
    let onDelete: (Set<UUID>) -> Void
    @State private var editingID: UUID?
    @State private var draftTitle = ""
    @FocusState private var focusedEditingID: UUID?

    var body: some View {
        List(selection: $selection) {
            if let live = state.liveRecording {
                LiveRecordingRow(state: state)
                    .tag(live.id)
                    .listRowSeparator(.hidden)
            }
            ForEach(RecordingDayGroup.make(state.recordings)) { group in
                Section {
                    ForEach(group.recordings) { recording in
                        RecordingRow(
                            recording: recording,
                            showsSeconds: group.needsSeconds(for: recording),
                            isEditing: editingID == recording.id,
                            editingTitle: $draftTitle,
                            focusedEditingID: $focusedEditingID,
                            onCommit: { commitRenaming(recording) },
                            onCancel: cancelRenaming
                        )
                            .tag(recording.id)
                            .listRowSeparator(.hidden)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                guard editingID == nil else { return }
                                beginRenaming(recording)
                            }
                            .accessibilityAction(named: "Rename") { beginRenaming(recording) }
                            .contextMenu {
                                Button("Rename…") { beginRenaming(recording) }
                                Divider()
                                Button("Move to Trash", role: .destructive) { onDelete([recording.id]) }
                            }
                    }
                } header: {
                    Text(group.title)
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                        .padding(.top, GlassTokens.Space.inline)
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) {
            guard editingID == nil else { return .ignored }
            guard selection.count == 1,
                  let id = selection.first,
                  let recording = state.recordings.first(where: { $0.id == id }) else { return .ignored }
            beginRenaming(recording)
            return .handled
        }
        .onDeleteCommand {
            guard editingID == nil else { return }
            onDelete(selection)
        }
        .onChange(of: focusedEditingID) { oldValue, newValue in
            guard let oldValue, newValue == nil, editingID == oldValue else { return }
            guard let recording = state.recordings.first(where: { $0.id == oldValue }) else {
                cancelRenaming()
                return
            }
            commitRenaming(recording)
        }
        .onChange(of: selection) { _, newSelection in
            guard let editingID, newSelection != [editingID],
                  let recording = state.recordings.first(where: { $0.id == editingID }) else { return }
            commitRenaming(recording)
        }
    }

    private func beginRenaming(_ recording: MeetingRecordingMetadata) {
        if let editingID, editingID != recording.id,
           let previous = state.recordings.first(where: { $0.id == editingID }) {
            commitRenaming(previous)
        }
        selection = [recording.id]
        draftTitle = recording.title ?? ""
        editingID = recording.id
        focusedEditingID = recording.id
    }

    private func commitRenaming(_ recording: MeetingRecordingMetadata) {
        onRename(recording.id, draftTitle)
        editingID = nil
        focusedEditingID = nil
    }

    private func cancelRenaming() {
        editingID = nil
        focusedEditingID = nil
    }
}

struct RecordingRow: View {
    let recording: MeetingRecordingMetadata
    var showsSeconds = false
    var isEditing = false
    var editingTitle: Binding<String>? = nil
    var focusedEditingID: FocusState<UUID?>.Binding? = nil
    var onCommit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    private var startTime: String {
        let format = Date.FormatStyle.dateTime.hour().minute()
        return recording.startedAt.formatted(showsSeconds ? format.second() : format)
    }

    private var warning: String? {
        RecordingsPlaceholder.endNote(for: recording.endReason)
            ?? RecordingsPlaceholder.degradedNote(for: recording)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: GlassTokens.Space.inline) {
                Image(systemName: recording.captureKind == .screen ? "rectangle.inset.filled" : "waveform")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(recording.captureKind == .screen ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                if isEditing, let editingTitle, let focusedEditingID {
                    TextField(
                        "Recording name",
                        text: editingTitle,
                        prompt: Text(RecordingsPlaceholder.defaultTitle(for: recording.startedAt))
                    )
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused(focusedEditingID, equals: recording.id)
                    .onSubmit { onCommit?() }
                    .onExitCommand { onCancel?() }
                    .accessibilityLabel("Recording name")
                } else {
                    Text(recording.title ?? startTime)
                        .font(.body)
                        .lineLimit(1)
                }
                Spacer(minLength: GlassTokens.Space.tight)
                Text(RecordingTime.clock(recording.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if recording.title != nil {
                Text(startTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(StatusColorRole.attention.color)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, GlassTokens.Space.tight)
        .help(recording.startedAt.formatted(date: .complete, time: .standard))
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(recording.title ?? RecordingsPlaceholder.defaultTitle(for: recording.startedAt))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = [
            recording.captureKind == .screen
                ? "Screen recording"
                : (recording.isMeeting ? "Meeting" : "Voice note"),
            RecordingTime.spoken(recording.duration),
            recording.startedAt.formatted(date: .abbreviated, time: .shortened),
        ]
        if let note = RecordingsPlaceholder.endNote(for: recording.endReason) { parts.append(note) }
        if let note = RecordingsPlaceholder.degradedNote(for: recording) { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

struct LiveRecordingRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: GlassTokens.Space.inline) {
            Circle()
                .fill(state.meetingState == .paused ? Color.secondary : StatusColorRole.recording.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(state.meetingState == .paused ? "Paused" : "Recording")
                .font(.body.weight(.medium))
        }
        .padding(.vertical, GlassTokens.Space.inline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.meetingState == .paused ? "Recording, paused" : "Recording")
        .accessibilityValue(RecordingTime.spoken(state.liveDuration))
    }
}

/// Both physical sources stay visible while browsing an older recording as well.
struct LiveLevelMeters: View {
    let levels: MeetingCapture.Levels
    let isPaused: Bool
    let showsOthers: Bool
    let othersDegraded: Bool
    var youDegraded: Bool = false
    @State private var you: [Float] = Array(repeating: 0, count: 24)
    @State private var others: [Float] = Array(repeating: 0, count: 24)

    var body: some View {
        HStack(spacing: GlassTokens.Space.section) {
            meter("You", samples: you, color: youDegraded ? StatusColorRole.attention.color : .accentColor)
            if showsOthers {
                meter("Others", samples: others, color: othersDegraded ? StatusColorRole.attention.color : .secondary)
            }
        }
        .onChange(of: levels) { _, levels in
            you.removeFirst()
            you.append(levels.microphone)
            others.removeFirst()
            others.append(levels.system)
        }
        .accessibilityHidden(true)
    }

    private func meter(_ title: String, samples: [Float], color: Color) -> some View {
        HStack(spacing: GlassTokens.Space.inline) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            RecordingWaveform(samples: samples, color: isPaused ? .secondary : color)
                .frame(width: 76, height: 22)
        }
    }
}
