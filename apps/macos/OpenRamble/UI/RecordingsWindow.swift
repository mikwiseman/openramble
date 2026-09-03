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

    var body: some View {
        NavigationSplitView {
            RecordingsList(state: state, selection: $selection)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 440)
                .toolbarBackground(.visible, for: .windowToolbar)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("Recordings")
        .sheet(isPresented: Binding(
            get: { state.isSystemAudioIntroPresented },
            set: { if !$0 { state.dismissSystemAudioIntro() } }
        )) {
            SystemAudioIntroSheet(state: state)
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
        } else if let selection, let recording = state.recordings.first(where: { $0.id == selection }) {
            RecordingDetail(state: state, recording: recording, player: player)
        } else {
            RecordingsPlaceholderView(
                placeholder: state.recordings.isEmpty && state.liveRecording == nil
                    ? .emptyLibrary
                    : .nothingSelected
            )
        }
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
