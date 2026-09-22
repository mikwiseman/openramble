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
    @State private var selection: UUID?
    @State private var recordingToRename: MeetingRecordingMetadata?
    @State private var renamedTitle = ""
    @State private var showsRename = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                RecordingsList(state: state, selection: $selection, onRename: beginRenaming)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                    .toolbarBackground(.visible, for: .windowToolbar)
            } detail: {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .clipped()
            }
            VStack(spacing: GlassTokens.Space.inline) {
                if state.meetingState == .recording { CaptureHealthStrip(state: state) }
                RecordBar(state: state)
                    .padding(.horizontal, GlassTokens.Space.stack)
                    .padding(.bottom, GlassTokens.Space.stack)
                    .padding(.top, GlassTokens.Space.inline)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("Recordings")
        .glassWindowBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy Transcript") {
                    if let selection { state.copyTranscript(selection) }
                }
                .help("Copy all text transcribed so far")
                .accessibilityIdentifier("copy-transcript")
                .disabled(selection.map { state.transcript(for: $0).isEmpty } ?? true)
            }
        }
        .onChange(of: selection) { _, id in
            if id != player.loadedID { player.pause() }
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
            if selection == nil { selection = state.liveRecording?.id ?? state.recordings.first?.id }
        }
        // A recording that just started or just finished is what the person
        // came to see.
        .onChange(of: state.liveRecording?.id) { _, id in
            if let id { selection = id }
        }
        .onChange(of: state.lastFinishedRecordingID) { _, id in
            if let id { selection = id }
        }
        .onChange(of: state.recordings) { _, recordings in
            if let selection, !recordings.contains(where: { $0.id == selection }),
               selection != state.liveRecording?.id {
                player.unload()
                self.selection = recordings.first?.id
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let live = state.liveRecording, selection == live.id {
            LiveRecordingDetail(state: state)
                .id(live.id)
        } else if let selection, let recording = state.recordings.first(where: { $0.id == selection }) {
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
        selection = recording.id
        recordingToRename = recording
        renamedTitle = recording.title ?? ""
        showsRename = true
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
