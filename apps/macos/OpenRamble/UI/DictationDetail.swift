import AVFoundation
import DictationCore
import SwiftUI

/// One dictation, read: its words large enough to read, and what can be done
/// with them.
///
/// Copy, reveal and delete live in the window's toolbar, the same for a
/// dictation as for a recording. Here are the three that belong to a
/// dictation alone: hear it, recognize it again, keep it past the limit.
struct DictationDetail: View {
    @ObservedObject var state: AppState
    let entry: HistoryEntry
    @ObservedObject var player: HistoryAudioPlayer

    private var audioURL: URL? { state.historyAudioURL(for: entry) }
    private var isPlaying: Bool { player.playingID == entry.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(entry.date.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: L10n.shared.language.locale)))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                // What was said, set as written text: large, in the serif,
                // with room to read.
                if entry.text.isEmpty {
                    Text(L10n.tr("Nothing recognized"))
                        .font(.words(26))
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.text)
                        .font(.words(26))
                        .lineSpacing(7)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: GlassTokens.Space.inline) {
                    if let audioURL {
                        Button {
                            player.toggle(entry.id, url: audioURL)
                        } label: {
                            Label(
                                isPlaying ? L10n.tr("Stop") : L10n.tr("Play"),
                                systemImage: isPlaying ? "stop.fill" : "play.fill"
                            )
                        }
                        .floatingButtonStyle()
                        .accessibilityLabel(isPlaying ? L10n.tr("Stop playback") : L10n.tr("Play this recording"))

                        Button {
                            state.retranscribeHistoryEntry(entry)
                        } label: {
                            Label(L10n.tr("Recognize again"), systemImage: "arrow.clockwise")
                        }
                        .floatingButtonStyle()
                        .disabled(state.isRetranscribing)
                        .help(L10n.tr("Recognize this recording again"))
                        .accessibilityLabel(L10n.tr("Recognize this recording again"))
                    } else {
                        Text(L10n.tr("Recording no longer on disk"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 0)

                    Toggle(isOn: Binding(
                        get: { entry.isKept },
                        set: { state.setHistoryEntryKept($0, for: entry) }
                    )) {
                        Label(L10n.tr("Keep"), systemImage: entry.isKept ? "star.fill" : "star")
                    }
                    .toggleStyle(.button)
                    .floatingButtonStyle()
                    .help(entry.isKept ? L10n.tr("Stop keeping this one") : L10n.tr("Keep this one"))
                    .accessibilityLabel(entry.isKept ? L10n.tr("Kept. Stop keeping") : L10n.tr("Keep this dictation"))
                }
                .controlSize(.large)
            }
            .frame(maxWidth: GlassTokens.Block.column, alignment: .leading)
            .padding(.horizontal, GlassTokens.Block.page + 8)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { player.stopIfPlaying(entry.id) }
    }
}

/// The waiting take, pinned to the top of the Library.
///
/// The take block holds the words where the person was working. The Library
/// is the second home: it opens from the Dock, Spotlight and the menu, so the
/// way back never depends on the menu bar mark. Here, and only here, the pin
/// also says how to stop the block from coming back, when that is known.
struct WaitingTakePin: View {
    @ObservedObject var state: AppState
    let waiting: WaitingWords

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StateGlyphView(glyph: waiting.glyph)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(waiting.reason(key: state.hotkey.shortTitle))
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Text(waiting.words)
                .font(.words(19))
                .lineSpacing(3)
                .lineLimit(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: GlassTokens.Space.inline) {
                if let fix = waiting.lastingFix {
                    Text(fix)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let note = waiting.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: GlassTokens.Space.inline)
                Button(L10n.tr("Later")) { state.keepWaitingWordsForLater() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityHint(L10n.tr("Keeps the words in History"))
                // This window is in front, so there is no field of someone
                // else's to paste into: copying is the action that works here.
                Button(L10n.tr("Copy")) { state.copyLastDictation() }
                    .buttonStyle(InkButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentBlock(.attention, padding: GlassTokens.Space.stack)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Words waiting."))
    }
}

/// Audio kept after an interrupted dictation: said once, on top of the list,
/// for as long as there is any. On every other day it costs nothing.
struct UnfinishedDictationsNote: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.recordingRecoveryStorageFaulted
                ? L10n.tr("Keeping interrupted recordings is switched off")
                : L10n.tr("Unfinished dictations: %@", String(describing: state.recoveredRecordingCount)))
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(state.recordingRecoveryStorageFaulted
                ? L10n.tr("The app could not record what is safe to delete, so it stops rather than guess about your voice data.")
                : L10n.tr("Their audio was kept so nothing was lost. It is deleted within seven days."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.tr("Show in Finder")) { state.revealRecoveredRecordings() }
                .controlSize(.small)
                .accessibilityHint(L10n.tr("Opens the folder holding the kept audio"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentBlock(.attention, padding: 12)
        .accessibilityElement(children: .contain)
    }
}

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
