import DictationAudio
import DictationCore
import SwiftUI

/// The library: recordings on the left, one recording on the right.
///
/// Two columns, not the three of the app this is modelled on. Its sidebar
/// exists to hold folders; this has none, so a sidebar would be empty chrome
/// and the transcript is what needs the room.
///
/// A plain `Window`, like Settings, and never opened by the app itself — not
/// on record, not on finish. Stealing the front from a full-screen call is
/// the one thing a meeting recorder must never do.
struct RecordingsWindow: View {
    static let windowID = "recordings"

    @ObservedObject var state: AppState
    @StateObject private var player = RecordingPlayer()
    @State private var selection = Set<UUID>()
    @State private var recordingToRename: MeetingRecordingMetadata?
    @State private var renamedTitle = ""
    @State private var showsRename = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                RecordingsList(
                    state: state,
                    selection: $selection,
                    onRename: beginRenaming,
                    onDelete: deleteRecordings
                )
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                    .toolbarBackground(.visible, for: .windowToolbar)
            } detail: {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .clipped()
            }
            VStack(spacing: 0) {
                Divider()
                if state.meetingState == .recording || state.meetingState == .paused {
                    CaptureHealthStrip(state: state)
                }
                RecordBar(state: state)
                    .padding(.horizontal, GlassTokens.Space.page)
                    .padding(.vertical, GlassTokens.Space.inline)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("Recordings")
        .glassWindowBackground()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let id = primarySelection { state.copyTranscript(id) }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 28, height: 28)
                }
                .help("Copy all text transcribed so far")
                .accessibilityLabel("Copy Transcript")
                .accessibilityIdentifier("copy-transcript")
                .buttonStyle(.borderless)
                .disabled(primarySelection.map { state.transcript(for: $0).isEmpty } ?? true)

                if !selection.isEmpty {
                    Button(role: .destructive, action: deleteSelectedRecordings) {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 28)
                    }
                    .help(selection.count == 1 ? "Move recording to Trash" : "Move selected recordings to Trash")
                    .accessibilityLabel(selection.count == 1 ? "Move recording to Trash" : "Move selected recordings to Trash")
                    .buttonStyle(.borderless)
                }
            }
        }
        .onChange(of: selection) { _, id in
            if id.count != 1 || id.first != player.loadedID { player.pause() }
        }
        .alert("Rename Recording", isPresented: $showsRename, presenting: recordingToRename) { recording in
            TextField(
                "Name", text: $renamedTitle,
                prompt: Text(RecordingsPlaceholder.defaultTitle(for: recording.startedAt))
            )
            .accessibilityLabel("Recording name")
            Button("Cancel", role: .cancel) { }
            Button("Save") { state.renameRecording(recording.id, title: renamedTitle) }
        } message: { _ in
            Text("Leave the name empty to use the date.")
        }
        .sheet(isPresented: Binding(
            get: { state.isSystemAudioIntroPresented },
            set: { if !$0 { state.dismissSystemAudioIntro() } }
        )) {
            SystemAudioIntroSheet(state: state)
        }
        .sheet(isPresented: Binding(
            get: { state.isScreenRecordingSetupPresented },
            set: { if !$0 { state.dismissScreenRecordingSetup() } }
        )) {
            ScreenRecordingSetup(state: state)
        }
        .onAppear {
            state.reloadRecordings()
            if selection.isEmpty, let id = state.liveRecording?.id ?? state.recordings.first?.id {
                selection = [id]
            }
        }
        // A recording that just started or just finished is what the person
        // came to see.
        .onChange(of: state.liveRecording?.id) { _, id in
            if let id { selection = [id] }
        }
        .onChange(of: state.lastFinishedRecordingID) { _, id in
            if let id { selection = [id] }
        }
        .onChange(of: state.recordings) { _, recordings in
            let available = Set(recordings.map(\.id)).union(state.liveRecording.map { [$0.id] } ?? [])
            if !selection.isSubset(of: available) {
                player.unload()
                self.selection = selection.intersection(available)
            }
            if selection.isEmpty, let id = recordings.first?.id {
                self.selection = [id]
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let live = state.liveRecording, primarySelection == live.id {
            LiveRecordingDetail(state: state)
                .id(live.id)
        } else if let selection = primarySelection,
                  let recording = state.recordings.first(where: { $0.id == selection }) {
            RecordingDetail(state: state, recording: recording, player: player) {
                beginRenaming(recording)
            }
                .id(recording.id)
        } else {
            RecordingsPlaceholderView(
                placeholder: state.recordings.isEmpty && state.liveRecording == nil
                    ? .emptyLibrary
                    : .nothingSelected
            )
        }
    }

    private func beginRenaming(_ recording: MeetingRecordingMetadata) {
        selection = [recording.id]
        recordingToRename = recording
        renamedTitle = recording.title ?? ""
        showsRename = true
    }

    private var primarySelection: UUID? {
        guard selection.count == 1 else { return nil }
        return selection.first
    }

    private func deleteSelectedRecordings() {
        deleteRecordings(selection)
    }

    private func deleteRecordings(_ ids: Set<UUID>) {
        let deletable = ids.filter { id in
            state.liveRecording?.id != id && state.recordings.contains { $0.id == id }
        }
        guard !deletable.isEmpty else { return }
        state.trashRecordings(deletable)
    }
}

struct RecordingsPlaceholderView: View {
    let placeholder: RecordingsPlaceholder

    var body: some View {
        ContentUnavailableView {
            Label(placeholder.title, systemImage: placeholder.symbol)
        } description: {
            Text(placeholder.detail)
        }
    }
}
