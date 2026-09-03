import DictationAudio
import DictationCore
import SwiftUI

/// One finished recording: its name, what it is, and its audio.
///
/// Leading-aligned like every other screen in the app. The transcript will
/// be the content here; until it exists the pane says so rather than leaving
/// a blank that reads as a bug.
struct RecordingDetail: View {
    @ObservedObject var state: AppState
    let recording: MeetingRecordingMetadata
    @ObservedObject var player: RecordingPlayer

    @State private var title = ""
    @FocusState private var isEditingTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, GlassTokens.Space.page)
                .padding(.top, GlassTokens.Space.section)
                .padding(.bottom, GlassTokens.Space.stack)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            RecordingTransport(player: player)
                .padding(.horizontal, GlassTokens.Space.page)
                .padding(.vertical, GlassTokens.Space.stack)
        }
        .onAppear(perform: load)
        .onChange(of: recording.id) { _, _ in load() }
        .onChange(of: recording.title) { _, new in if !isEditingTitle { title = new ?? "" } }
        .onKeyPress(.space) {
            guard !isEditingTitle else { return .ignored }
            player.toggle()
            return .handled
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    state.copyTranscript(recording.id)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .help("Copy the transcript")
                .disabled(state.transcript(for: recording.id).isEmpty)
                Button {
                    state.revealRecording(recording.id)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show the audio file in Finder")
                Button(role: .destructive) {
                    state.trashRecording(recording.id)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .help("Move this recording to the Trash")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GlassTokens.Space.tight) {
            TextField(
                RecordingsPlaceholder.defaultTitle(for: recording.startedAt),
                text: $title
            )
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .focused($isEditingTitle)
            .onSubmit { commitTitle() }
            .onChange(of: isEditingTitle) { _, editing in if !editing { commitTitle() } }
            .accessibilityLabel("Title")
            .accessibilityHint("Press Return to rename")

            Text(metadataLine)
                .font(.system(size: GlassTokens.Label.footnote))
                .foregroundStyle(.secondary)
        }
    }

    private var metadataLine: String {
        var parts = [
            recording.startedAt.formatted(date: .long, time: .shortened),
            RecordingTime.brief(recording.duration),
            recording.isMeeting ? "Meeting" : "Voice note",
        ]
        if let bytes = state.recordingBytes(recording.id) {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: GlassTokens.Space.stack) {
            if let note = RecordingsPlaceholder.endNote(for: recording.endReason) {
                HStack(alignment: .firstTextBaseline, spacing: GlassTokens.Space.inline) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StatusColorRole.attention.color)
                        .accessibilityHidden(true)
                    Text(note)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(GlassTokens.Space.stack)
                .contentSurface(RoundedRectangle(cornerRadius: GlassTokens.Radius.control, style: .continuous))
                .padding(.horizontal, GlassTokens.Space.page)
                .padding(.top, GlassTokens.Space.section)
            }
            let utterances = state.transcript(for: recording.id)
            if !utterances.isEmpty {
                TranscriptView(
                    utterances: utterances,
                    currentTime: player.isPlaying || player.currentTime > 0 ? player.currentTime : nil,
                    onSeek: { time in
                        player.seek(to: time)
                        if !player.isPlaying { player.toggle() }
                    }
                )
            } else if player.failedToLoad {
                RecordingsPlaceholderView(placeholder: .audioMissing)
            } else {
                RecordingsPlaceholderView(
                    placeholder: state.transcribingRecordingID == recording.id
                        ? .stillTranscribing
                        : .transcript(for: recording.transcriptionState)
                )
            }
            if state.transcribingRecordingID == recording.id {
                TranscriptStatusLine(state: state)
            }
        }
    }

    private func load() {
        title = recording.title ?? ""
        state.loadTranscript(recording.id)
        player.load(id: recording.id, url: state.recordingAudioURL(recording.id))
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (recording.title ?? "") else { return }
        state.renameRecording(recording.id, title: trimmed)
    }
}

/// The recording in progress, in the detail column: the time, the meter,
/// and the controls. No scrubber and no transport — you cannot seek what has
/// not finished, and playing a recording into the microphone that is
/// recording it is a feedback loop.
struct LiveRecordingDetail: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: GlassTokens.Space.section) {
                Text(RecordingTime.clock(state.liveDuration))
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel(state.meetingState == .paused ? "Paused" : "Recording")
                    .accessibilityValue(RecordingTime.spoken(state.liveDuration))
                LiveLevelMeter(levels: state.liveLevels, isPaused: state.meetingState == .paused)
                    .frame(maxWidth: 240, minHeight: 28, maxHeight: 28)
                Spacer()
                Text(state.meetingState == .paused ? "Paused" : "Recording your microphone")
                    .font(.system(size: GlassTokens.Label.footnote))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, GlassTokens.Space.page)
            .padding(.top, GlassTokens.Space.section)
            .padding(.bottom, GlassTokens.Space.stack)
            Divider()
            if state.liveTranscript.isEmpty {
                RecordingsPlaceholderView(placeholder: .listening)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(utterances: state.liveTranscript)
            }
            Divider()
            TranscriptStatusLine(state: state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
