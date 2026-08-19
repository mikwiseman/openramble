import AVFoundation
import SwiftUI

/// Recent dictations, with the audio that produced them.
///
/// Every take is here, not only the ones that went wrong. The mechanism this
/// replaces surfaced a recording solely when insertion had failed, through a
/// menu item and a Finder window; it was invisible on the days it worked, which
/// is most days. A list you can play back is the same guarantee made useful.
struct HistoryView: View {
    @ObservedObject var state: AppState
    @StateObject private var player = HistoryAudioPlayer()
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Dictations that never became text, kept as audio so nothing was
            // lost. They belong here, with the other recordings — they used to
            // sit under the speech model beside "Delete Model", which is a
            // section about the recogniser and has nothing to do with them.
            if state.recoveredRecordingCount > 0 || state.recordingRecoveryStorageFaulted {
                unfinished
                Divider()
            }
            if state.history.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No dictations yet")
                .font(.headline)
            Text("Finished dictations appear here with their audio.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(state.history) { entry in
                    HistoryRow(
                        entry: entry,
                        audioURL: state.historyAudioURL(for: entry),
                        player: player,
                        onCopy: { state.copyHistoryEntry(entry) },
                        onDelete: {
                            player.stopIfPlaying(entry.id)
                            state.deleteHistoryEntry(entry)
                        },
                        onToggleKept: { state.setHistoryEntryKept(!entry.isKept, for: entry) },
                        onRetranscribe: { state.retranscribeHistoryEntry(entry) },
                        isRetranscribing: state.isRetranscribing
                    )
                    Divider()
                }
            }
        }
    }

    /// The takes that were interrupted, and the one state where keeping them
    /// stops working.
    private var unfinished: some View {
        HStack(spacing: 10) {
            Image(systemName: state.recordingRecoveryStorageFaulted
                ? "exclamationmark.triangle.fill"
                : "waveform.badge.exclamationmark")
                .foregroundStyle(StatusColorRole.attention.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.recordingRecoveryStorageFaulted
                    ? "Keeping interrupted recordings is switched off"
                    : "\(state.recoveredRecordingCount) dictation\(state.recoveredRecordingCount == 1 ? "" : "s") didn't finish")
                    .font(.callout.weight(.medium))
                Text(state.recordingRecoveryStorageFaulted
                    ? "The app could not record what is safe to delete, so it stops rather than guess about your voice data."
                    : "Their audio was kept so nothing was lost. It is deleted within seven days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Show in Finder") { state.revealRecoveredRecordings() }
                .accessibilityHint("Opens the folder holding the kept audio")
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack {
            Picker("Keep", selection: $state.historyLimit) {
                ForEach([5, 10, 20, 50], id: \.self) { count in
                    Text("Last \(count)").tag(count)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
            .accessibilityHint("How many dictations to keep, with their audio")

            Spacer()

            Button("Show Recordings") { state.revealHistoryAudio() }
                .disabled(state.history.isEmpty)
                .accessibilityHint("Opens the folder holding the audio kept with these dictations")

            Button("Delete All", role: .destructive) { showClearConfirmation = true }
                .disabled(state.history.isEmpty)
        }
        .padding(12)
        .confirmationDialog(
            "Delete all dictation history?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                player.stop()
                state.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcripts and their recordings are removed from this Mac.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let audioURL: URL?
    @ObservedObject var player: HistoryAudioPlayer
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onToggleKept: () -> Void
    let onRetranscribe: () -> Void
    let isRetranscribing: Bool

    private var isPlaying: Bool { player.playingID == entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onToggleKept) {
                    Image(systemName: entry.isKept ? "star.fill" : "star")
                        .foregroundStyle(entry.isKept ? StatusColorRole.attention.color : .secondary)
                }
                .buttonStyle(.borderless)
                .help(entry.isKept ? "Stop keeping this one" : "Keep this one")
                .accessibilityLabel(entry.isKept ? "Kept. Stop keeping" : "Keep this dictation")

                if audioURL != nil {
                    Button(action: onRetranscribe) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRetranscribing)
                    .help("Recognise this recording again")
                    .accessibilityLabel("Recognise this recording again")
                }

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                .accessibilityLabel("Copy this dictation")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
                .accessibilityLabel("Delete this dictation")
            }

            Text(entry.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let audioURL {
                Button {
                    player.toggle(entry.id, url: audioURL)
                } label: {
                    Label(
                        isPlaying ? "Stop" : "Play",
                        systemImage: isPlaying ? "stop.fill" : "play.fill"
                    )
                    .font(.callout)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPlaying ? "Stop playback" : "Play this recording")
            } else {
                // Said rather than hidden: a row without a Play button and no
                // explanation reads as a bug.
                Text("Recording no longer on disk")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One take playing at a time.
///
/// The panel is not the point here — hearing what was actually said is — so a
/// second Play stops the first rather than layering two recordings.
@MainActor
final class HistoryAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(_ id: UUID, url: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        guard let created = try? AVAudioPlayer(contentsOf: url) else { return }
        created.delegate = self
        player = created
        playingID = id
        created.play()
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func stopIfPlaying(_ id: UUID) {
        guard playingID == id else { return }
        stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
