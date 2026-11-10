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
    @StateObject private var dictationPlayer = HistoryAudioPlayer()
    @State private var selection = Set<UUID>()
    @State private var scope = LibraryScope.all
    @State private var query = ""

    /// Everything said, by day: what the list shows.
    private var days: [LibraryDay] {
        LibraryIndex.days(
            dictations: state.history,
            recordings: state.recordings,
            scope: scope,
            query: query
        )
    }

    private var listedIDs: [UUID] { days.flatMap(\.items).map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                RecordingsList(
                    state: state,
                    selection: $selection,
                    days: days,
                    onRename: { id, title in state.renameRecording(id, title: title) },
                    onDelete: deleteItems
                )
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: GlassTokens.Space.inline) {
                            Picker(L10n.tr("Show"), selection: $scope) {
                                ForEach(LibraryScope.allCases) { scope in
                                    Text(scope.title).tag(scope)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityLabel(L10n.tr("Show"))
                            if state.recoveredRecordingCount > 0 || state.recordingRecoveryStorageFaulted {
                                UnfinishedDictationsNote(state: state)
                            }
                        }
                        .padding(.horizontal, GlassTokens.Space.inline)
                        .padding(.vertical, GlassTokens.Space.tight)
                    }
                    .searchable(text: $query, placement: .sidebar, prompt: Text(L10n.tr("Search what you said")))
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
                    .toolbarBackground(.visible, for: .windowToolbar)
            } detail: {
                VStack(spacing: 0) {
                    // Words that could not land, wherever the person came
                    // from: the Dock, Spotlight or the menu.
                    if let waiting = state.waitingWords {
                        WaitingTakePin(state: state, waiting: waiting)
                            .padding([.horizontal, .top], GlassTokens.Space.stack)
                    }
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The record control floats: a capsule of glass over whatever
                // is being read, with the page scrolling beneath it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: GlassTokens.Space.inline) {
                        if state.meetingState == .recording || state.meetingState == .paused {
                            CaptureHealthStrip(state: state)
                        }
                        RecordBar(state: state)
                    }
                    .padding(.horizontal, GlassTokens.Space.section)
                    .padding(.bottom, GlassTokens.Space.stack)
                }
                // A floor for the column's own measurement. Asked for its
                // smallest size, a split view proposes no width at all, and
                // text that wraps then reports one word per line: the pin
                // claimed more height than the window had, and the whole
                // content slid out from under the toolbar.
                .frame(minWidth: 440)
                .background(Color(nsColor: .textBackgroundColor))
                .clipped()
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle(L10n.tr("Library"))
        .glassWindowBackground()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if selectedDictation != nil {
                        state.revealHistoryAudio()
                    } else if let id = primarySelection {
                        state.revealRecording(id)
                    }
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 28, height: 28)
                }
                .help(selectedDictation == nil ? L10n.tr("Open recording in Finder") : L10n.tr("Show in Finder"))
                .accessibilityLabel(L10n.tr("Open in Finder"))
                .accessibilityIdentifier("open-recording-in-finder")
                .buttonStyle(.borderless)
                .disabled(primarySelection == nil)

                Button {
                    if let entry = selectedDictation {
                        state.copyHistoryEntry(entry)
                    } else if let id = primarySelection {
                        state.copyTranscript(id)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 28, height: 28)
                }
                .help(selectedDictation == nil ? L10n.tr("Copy all text transcribed so far") : L10n.tr("Copy"))
                .accessibilityLabel(selectedDictation == nil ? L10n.tr("Copy Transcript") : L10n.tr("Copy this dictation"))
                .accessibilityIdentifier("copy-transcript")
                .buttonStyle(.borderless)
                .disabled(isCopyDisabled)

                if !selection.isEmpty {
                    Button(role: .destructive, action: { deleteItems(selection) }) {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 28)
                    }
                    .help(deleteTitle)
                    .accessibilityLabel(deleteTitle)
                    .buttonStyle(.borderless)
                }
            }
        }
        .onChange(of: selection) { _, id in
            if id.count != 1 || id.first != player.loadedID { player.pause() }
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
            if selection.isEmpty, let id = state.liveRecording?.id ?? listedIDs.first {
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
        .onChange(of: listedIDs) { _, listed in
            // What is selected has to be something the list still shows: an
            // item deleted, or filtered out by the search, leaves the detail.
            let available = Set(listed).union(state.liveRecording.map { [$0.id] } ?? [])
            if !selection.isSubset(of: available) {
                player.unload()
                self.selection = selection.intersection(available)
            }
            if selection.isEmpty, let id = listed.first {
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
            RecordingDetail(state: state, recording: recording, player: player)
                .id(recording.id)
        } else if let entry = selectedDictation {
            DictationDetail(state: state, entry: entry, player: dictationPlayer)
                .id(entry.id)
        } else {
            RecordingsPlaceholderView(
                placeholder: placeholder
            )
        }
    }

    private var placeholder: RecordingsPlaceholder {
        if state.recordings.isEmpty, state.history.isEmpty, state.liveRecording == nil {
            return .emptyLibrary
        }
        return listedIDs.isEmpty ? .nothingFound : .nothingSelected
    }

    private var selectedDictation: HistoryEntry? {
        guard let id = primarySelection else { return nil }
        return state.history.first { $0.id == id }
    }

    private var isCopyDisabled: Bool {
        if let entry = selectedDictation { return entry.text.isEmpty }
        return primarySelection.map { state.transcript(for: $0).isEmpty } ?? true
    }

    private var deleteTitle: String {
        let dictations = selection.filter { id in state.history.contains { $0.id == id } }.count
        if dictations == selection.count {
            return selection.count == 1 ? L10n.tr("Delete this dictation") : L10n.tr("Delete selected dictations")
        }
        if dictations == 0 {
            return selection.count == 1 ? L10n.tr("Move recording to Trash") : L10n.tr("Move selected recordings to Trash")
        }
        return L10n.tr("Delete selected items")
    }

    private var primarySelection: UUID? {
        guard selection.count == 1 else { return nil }
        return selection.first
    }

    /// Recordings go to the Trash; dictations are deleted, audio and all, as
    /// they always were. A live recording cannot be deleted from under itself.
    private func deleteItems(_ ids: Set<UUID>) {
        for entry in state.history where ids.contains(entry.id) {
            dictationPlayer.stopIfPlaying(entry.id)
            state.deleteHistoryEntry(entry)
        }
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
