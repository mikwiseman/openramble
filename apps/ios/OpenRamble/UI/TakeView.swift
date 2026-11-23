import AVFoundation
import SwiftUI

/// One take on its own page: the words, to read, fix and send on; the
/// recording, to hear what was really said.
struct TakeView: View {
    let id: Take.ID
    @Environment(TakeStore.self) private var store
    @Environment(Dictation.self) private var dictation
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var player = AudioPlayer()
    @State private var confirmsDelete = false

    var body: some View {
        if let take = store.take(id) {
            page(take)
        } else {
            ContentUnavailableView("Deleted", systemImage: "trash")
        }
    }

    private func page(_ take: Take) -> some View {
        content(take)
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !loaded else { return }
                text = take.text
                loaded = true
            }
            .onChange(of: take.text) { _, written in
                // The words arrived while this page was open.
                if text.isEmpty { text = written }
            }
            .task(id: text) {
                // Edits are kept a moment after typing stops.
                guard loaded, text != take.text, take.state == .written else { return }
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, var edited = store.take(id) else { return }
                edited.text = text
                store.update(edited)
            }
            .onDisappear { player.stop() }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(take.recordedAt.formatted(.dateTime.weekday(.wide).hour().minute()))
                            .font(.subheadline)
                        Text(details(take))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let audio = store.audioURL(for: take) {
                        Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                            player.toggle(audio)
                        }
                    }
                    Spacer()
                    if take.hasWords {
                        Button("Copy", systemImage: "doc.on.doc") {
                            var current = take
                            current.text = text
                            dictation.copy(current)
                        }
                        ShareLink(item: text)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        confirmsDelete = true
                    }
                }
            }
            .confirmationDialog("Delete this take?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Take", role: .destructive) {
                    player.stop()
                    store.delete(id)
                    dismiss()
                }
            } message: {
                Text("Its words and its recording are removed from this iPhone.")
            }
            .overlay(alignment: .bottom) {
                NoticeView().padding(.bottom, 12)
            }
    }

    @ViewBuilder private func content(_ take: Take) -> some View {
        switch take.state {
        case .written:
            TextEditor(text: $text)
                .font(Theme.page)
                .lineSpacing(Theme.leading)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, Theme.margin - 5)
                .padding(.top, 8)
        case .writing:
            status { WritingLine() }
        case .silent:
            status {
                Text("No words heard in this recording.")
                    .font(Theme.page.italic())
                    .foregroundStyle(.secondary)
            }
        case let .failed(reason):
            status {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Not written.")
                        .font(Theme.page.italic())
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await dictation.write(take.id) } }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private func status(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, Theme.margin)
            .padding(.top, 16)
    }

    private func details(_ take: Take) -> String {
        var parts: [String] = []
        if take.duration > 0 { parts.append(Take.clock(take.duration)) }
        if take.source == .file { parts.append("from a file") }
        if let seconds = take.writtenIn, take.state == .written {
            parts.append("written in \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// Plays a take's recording.
@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if isPlaying {
            stop()
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        isPlaying = true
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
