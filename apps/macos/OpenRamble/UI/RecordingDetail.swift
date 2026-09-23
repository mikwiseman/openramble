import AppKit
import DictationAudio
import DictationCore
import SwiftUI
import UniformTypeIdentifiers

/// One finished recording: its name, what it is, and its audio.
///
/// Leading-aligned like every other screen in the app. The transcript will
/// be the content here; until it exists the pane says so rather than leaving
/// a blank that reads as a bug.
struct RecordingDetail: View {
    @ObservedObject var state: AppState
    let recording: MeetingRecordingMetadata
    @ObservedObject var player: RecordingPlayer

    @State private var showsInfo = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var titleIsFocused: Bool

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
        .onKeyPress(.space) {
            guard !isRenaming, !titleIsFocused else { return .ignored }
            player.toggle()
            return .handled
        }
        .onChange(of: titleIsFocused) { _, focused in
            guard !focused, isRenaming else { return }
            commitRename()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename…", action: beginRenaming)
                    Button("Save Transcript…") { saveTranscript() }
                        .disabled(state.transcript(for: recording.id).isEmpty)
                    Button("Save Audio…") { saveAudio() }
                        .disabled(state.recordingAudioURL(recording.id) == nil || state.audioExportProgress != nil)
                    if recording.captureKind == .screen {
                        Button("Save Video…") { saveVideo() }
                            .disabled(state.recordingVideoURL(recording.id) == nil)
                    }
                    Divider()
                    Button("Show in Finder") { state.revealRecording(recording.id) }
                    Button("Recording Details…") { showsInfo = true }
                    Divider()
                    Button("Move to Trash", role: .destructive) { state.trashRecording(recording.id) }
                }
                label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Recording details and actions")
                .accessibilityLabel("More recording actions")
                .popover(isPresented: $showsInfo) {
                    VStack(alignment: .leading, spacing: GlassTokens.Space.inline) {
                        Text("Recording Details").font(.headline)
                        Text(metadataLine).font(.callout).textSelection(.enabled)
                    }
                    .padding(GlassTokens.Space.section)
                    .frame(width: 320)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GlassTokens.Space.tight) {
            if isRenaming {
                TextField(
                    "Recording name",
                    text: $draftTitle,
                    prompt: Text(RecordingsPlaceholder.defaultTitle(for: recording.startedAt))
                )
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($titleIsFocused)
                .onSubmit(commitRename)
                .onExitCommand(perform: cancelRename)
                .accessibilityLabel("Recording name")
                .task { titleIsFocused = true }
            } else {
                Text(recording.title ?? RecordingsPlaceholder.defaultTitle(for: recording.startedAt))
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginRenaming)
                    .help("Double-click to rename")
                    .accessibilityIdentifier("rename-recording")
            }

            Text(recording.title == nil
                 ? RecordingTime.brief(recording.duration)
                 : recording.startedAt.formatted(date: .long, time: .shortened)
                    + " · " + RecordingTime.brief(recording.duration))
                .font(.system(size: GlassTokens.Label.footnote))
                .foregroundStyle(.secondary)
        }
    }

    private var metadataLine: String {
        var parts = [
            recording.startedAt.formatted(date: .long, time: .shortened),
            RecordingTime.brief(recording.duration),
            recording.captureKind == .screen
                ? "Screen recording"
                : (recording.isMeeting ? "Meeting" : "Voice note"),
        ]
        if let transport = recording.systemAudio.outputTransport, recording.isMeeting {
            parts.append("other side via \(transport)")
        }
        if let bytes = state.recordingBytes(recording.id) {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: GlassTokens.Space.stack) {
            if recording.captureKind == .screen {
                if let videoPlayer = player.videoPlayer {
                    ZStack {
                        LocalRecordingVideo(player: videoPlayer)
                        if !player.isPlaying, player.currentTime < 0.05 {
                            if let preview = player.videoPreviewImage {
                                Image(nsImage: preview)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .transition(.opacity)
                            } else {
                                Rectangle()
                                    .fill(Color(nsColor: .windowBackgroundColor))
                                    .overlay { ProgressView() }
                            }
                        }
                    }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: GlassTokens.Radius.surface, style: .continuous))
                        .padding(.horizontal, GlassTokens.Space.page)
                        .padding(.top, GlassTokens.Space.section)
                        .accessibilityLabel("Screen recording video")
                } else if player.videoFailedToLoad {
                    LocalRecordingVideoPlaceholder(
                        title: "Video unavailable",
                        detail: "The audio and transcript are still available."
                    )
                    .padding(.horizontal, GlassTokens.Space.page)
                    .padding(.top, GlassTokens.Space.section)
                }
            }
            if let progress = state.audioExportProgress {
                HStack(spacing: GlassTokens.Space.inline) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text("Preparing the audio…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: GlassTokens.Space.inline)
                    Button("Cancel") { state.cancelAudioExport() }
                }
                .padding(GlassTokens.Space.stack)
                .contentSurface(RoundedRectangle(cornerRadius: GlassTokens.Radius.control, style: .continuous))
                .padding(.horizontal, GlassTokens.Space.page)
                .padding(.top, GlassTokens.Space.section)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Preparing the audio")
                .accessibilityValue("\(Int(progress * 100)) percent")
            }
            if let note = RecordingsPlaceholder.endNote(for: recording.endReason)
                ?? RecordingsPlaceholder.degradedNote(for: recording) {
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
            } else if player.failedToLoad && player.videoPlayer == nil {
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
        state.loadTranscript(recording.id)
        player.load(
            id: recording.id,
            url: state.recordingAudioURL(recording.id),
            videoURL: recording.captureKind == .screen ? state.recordingVideoURL(recording.id) : nil
        )
    }

    private func beginRenaming() {
        draftTitle = recording.title ?? ""
        isRenaming = true
        titleIsFocused = true
    }

    private func commitRename() {
        state.renameRecording(recording.id, title: draftTitle)
        isRenaming = false
        titleIsFocused = false
    }

    private func cancelRename() {
        isRenaming = false
        titleIsFocused = false
    }

    private func saveTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(state.exportName(recording.id)).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportTranscript(recording.id, to: url)
    }

    private func saveAudio() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = "\(state.exportName(recording.id)).m4a"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportAudio(recording.id, to: url)
    }

    private func saveVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(state.exportName(recording.id)).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportVideo(recording.id, to: url)
    }
}

/// The live document. The shared transport remains visible outside this pane.
struct LiveRecordingDetail: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.liveTranscript.isEmpty {
                Text(RecordingsPlaceholder.listening.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(GlassTokens.Space.page)
                    .accessibilityLabel(state.meetingState == .paused ? "Recording paused" : RecordingsPlaceholder.listening.title)
                    .accessibilityValue(RecordingsPlaceholder.listening.detail)
                Spacer(minLength: 0)
            } else {
                TranscriptView(utterances: state.liveTranscript, followsLive: true)
            }
            TranscriptStatusLine(state: state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
