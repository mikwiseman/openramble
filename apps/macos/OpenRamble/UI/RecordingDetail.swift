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

    @State private var title = ""
    @FocusState private var isEditingTitle: Bool
    /// The toolbar view the system share menu points at. AppKit wants a real
    /// view to hang the popover from, and a menu item is not one.
    @State private var shareAnchor = ShareAnchor.Box()

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
                Menu {
                    Button("Save Transcript…") { saveTranscript() }
                        .disabled(state.transcript(for: recording.id).isEmpty)
                    Button("Save Audio…") { saveAudio() }
                        .disabled(state.recordingAudioURL(recording.id) == nil)
                    Divider()
                    // The meeting, not one half of it: the transcript to read
                    // and the audio to hear, handed to whichever app is picked.
                    Button("Share…") { share() }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Save or share this recording")
                .disabled(state.audioExportProgress != nil)
                ShareAnchor(box: shareAnchor)
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
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

    private func share() {
        Task {
            let items = await state.prepareShareItems(recording.id)
            guard !items.isEmpty, let view = shareAnchor.view else { return }
            NSSharingServicePicker(items: items).show(
                relativeTo: view.bounds,
                of: view,
                preferredEdge: .minY
            )
        }
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
                LiveLevelMeters(
                    levels: state.liveLevels,
                    isPaused: state.meetingState == .paused,
                    showsOthers: state.liveRecording?.isMeeting ?? false,
                    othersDegraded: state.liveCaptureHealth.marksRecordingDegraded
                )
                .frame(maxWidth: 300, minHeight: (state.liveRecording?.isMeeting ?? false) ? 52 : 28)
                Spacer()
                Text(liveLine)
                    .font(.system(size: GlassTokens.Label.footnote))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, GlassTokens.Space.page)
            .padding(.top, GlassTokens.Space.section)
            .padding(.bottom, GlassTokens.Space.stack)
            CaptureHealthStrip(state: state)
                .padding(.bottom, GlassTokens.Space.stack)
            if state.liveRecording?.isMeeting ?? false, state.liveCaptureHealth.title == nil {
                // No processing beats this. On speakers the other side reaches
                // the microphone and has to be told apart from the person;
                // on headphones there is nothing to tell apart.
                Text("On speakers, the Mac's own audio reaches your microphone. Headphones keep the two sides apart.")
                    .font(.system(size: GlassTokens.Label.footnote))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, GlassTokens.Space.page)
                    .padding(.bottom, GlassTokens.Space.stack)
            }
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

    private var liveLine: String {
        if state.meetingState == .paused { return "Paused" }
        return (state.liveRecording?.isMeeting ?? false)
            ? "Recording you and the other side"
            : "Recording your microphone"
    }
}

/// A one-pixel handle into AppKit.
///
/// `NSSharingServicePicker` points its popover at a view, and a SwiftUI menu
/// item is not one. This sits beside the menu in the toolbar and lends the
/// picker somewhere to appear, which is why it is invisible rather than
/// merely small.
struct ShareAnchor: NSViewRepresentable {
    @MainActor final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}
