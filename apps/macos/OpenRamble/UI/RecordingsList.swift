import DictationAudio
import DictationCore
import SwiftUI

/// Newest first, grouped by local day. The recording in progress stays pinned above the archive.
struct RecordingsList: View {
    @ObservedObject var state: AppState
    @Binding var selection: Set<UUID>
    let days: [LibraryDay]
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
            ForEach(days) { day in
                Section {
                    ForEach(day.items) { item in
                        switch item {
                        case let .dictation(entry):
                            DictationRow(entry: entry)
                                .tag(entry.id)
                                .listRowSeparator(.hidden)
                                .contextMenu {
                                    Button(L10n.tr("Copy")) { state.copyHistoryEntry(entry) }
                                        .disabled(entry.text.isEmpty)
                                    Button(entry.isKept ? L10n.tr("Stop keeping this one") : L10n.tr("Keep this one")) {
                                        state.setHistoryEntryKept(!entry.isKept, for: entry)
                                    }
                                    Divider()
                                    Button(L10n.tr("Delete"), role: .destructive) { onDelete([entry.id]) }
                                }
                        case let .recording(recording):
                            RecordingRow(
                                recording: recording,
                                showsSeconds: day.needsSeconds(for: recording),
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
                                .accessibilityAction(named: L10n.tr("Rename")) { beginRenaming(recording) }
                                .contextMenu {
                                    Button(L10n.tr("Rename…")) { beginRenaming(recording) }
                                    Divider()
                                    Button(L10n.tr("Move to Trash"), role: .destructive) { onDelete([recording.id]) }
                                }
                        }
                    }
                } header: {
                    Text(day.title)
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

/// A dictation in the list: its first words, when it was said, and a star
/// if it is kept past the limit.
struct DictationRow: View {
    let entry: HistoryEntry

    private var time: String {
        entry.date.formatted(Date.FormatStyle.dateTime.hour().minute().locale(L10n.shared.language.locale))
    }

    var body: some View {
        HStack(alignment: .top, spacing: GlassTokens.Space.inline) {
            RowDisc(symbol: "text.quote")
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text.isEmpty ? L10n.tr("Nothing recognized") : entry.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(entry.text.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: GlassTokens.Space.tight) {
                    Text(time)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if entry.isKept {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.vertical, GlassTokens.Space.tight)
        .help(entry.date.formatted(Date.FormatStyle(date: .complete, time: .standard, locale: L10n.shared.language.locale)))
        .accessibilityElement(children: .ignore)
        // The time, not the words: the row is a place in a list, and the
        // words are read from the detail when the person asks for them.
        .accessibilityLabel(L10n.tr("Dictation"))
        .accessibilityValue(
            entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.shared.language.locale))
                + (entry.isKept ? ", " + L10n.tr("Kept") : "")
        )
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
        let format = Date.FormatStyle.dateTime.hour().minute().locale(L10n.shared.language.locale)
        return recording.startedAt.formatted(showsSeconds ? format.second() : format)
    }

    private var warning: String? {
        RecordingsPlaceholder.endNote(for: recording.endReason)
            ?? RecordingsPlaceholder.degradedNote(for: recording)
    }

    private var symbol: String {
        if recording.captureKind == .screen { return "rectangle.inset.filled" }
        return recording.isMeeting ? "person.2.fill" : "mic.fill"
    }

    private var kind: String {
        if recording.captureKind == .screen { return L10n.tr("Screen recording") }
        return recording.isMeeting ? L10n.tr("Meeting") : L10n.tr("Voice note")
    }

    var body: some View {
        HStack(alignment: .top, spacing: GlassTokens.Space.inline) {
            RowDisc(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: GlassTokens.Space.inline) {
                    if isEditing, let editingTitle, let focusedEditingID {
                        TextField(
                            L10n.tr("Recording name"),
                            text: editingTitle,
                            prompt: Text(RecordingsPlaceholder.defaultTitle(for: recording.startedAt))
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .focused(focusedEditingID, equals: recording.id)
                        .onSubmit { onCommit?() }
                        .onExitCommand { onCancel?() }
                        .accessibilityLabel(L10n.tr("Recording name"))
                    } else {
                        Text(recording.title ?? kind)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                    Spacer(minLength: GlassTokens.Space.tight)
                    Text(RecordingTime.clock(recording.duration))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(startTime)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(StatusColorRole.attention.color)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, GlassTokens.Space.tight)
        .help(recording.startedAt.formatted(Date.FormatStyle(date: .complete, time: .standard, locale: L10n.shared.language.locale)))
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(recording.title ?? RecordingsPlaceholder.defaultTitle(for: recording.startedAt))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = [
            recording.captureKind == .screen
                ? L10n.tr("Screen recording")
                : (recording.isMeeting ? L10n.tr("Meeting") : L10n.tr("Voice note")),
            RecordingTime.spoken(recording.duration),
            recording.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.shared.language.locale)),
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
            Text(state.meetingState == .paused ? L10n.tr("Paused") : L10n.tr("Recording"))
                .font(.body.weight(.medium))
        }
        .padding(.vertical, GlassTokens.Space.inline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.meetingState == .paused ? L10n.tr("Recording, paused") : L10n.tr("Recording"))
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
            meter(L10n.tr("You"), samples: you, color: youDegraded ? StatusColorRole.attention.color : .accentColor)
            if showsOthers {
                meter(L10n.tr("Others"), samples: others, color: othersDegraded ? StatusColorRole.attention.color : .secondary)
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
