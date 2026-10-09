import SwiftUI

/// Position and play controls for one recording.
///
/// The slider is the position; there is no separate progress bar. While the
/// person drags, the player pauses and follows the thumb, and resumes if it
/// was playing — the drag is the seek, not a request for one.
struct RecordingTransport: View {
    @ObservedObject var player: RecordingPlayer
    @State private var scrubPosition: TimeInterval?
    @State private var wasPlayingBeforeScrub = false

    private var position: TimeInterval { scrubPosition ?? player.currentTime }

    var body: some View {
        HStack(spacing: GlassTokens.Space.inline) {
            HStack(spacing: GlassTokens.Space.tight) {
                Button { player.skip(by: -RecordingPlayer.skipInterval) } label: {
                    Image(systemName: "gobackward.15").font(.title3)
                }
                .accessibilityLabel(L10n.tr("Skip back 15 seconds"))
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(player.isPlaying ? L10n.tr("Pause") : L10n.tr("Play"))
                Button { player.skip(by: RecordingPlayer.skipInterval) } label: {
                    Image(systemName: "goforward.15").font(.title3)
                }
                .accessibilityLabel(L10n.tr("Skip forward 15 seconds"))
            }
            .buttonStyle(.borderless)
            .disabled(player.duration == 0)
            Text(RecordingTime.clock(position))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Slider(
                value: Binding(get: { position }, set: { scrubPosition = $0 }),
                in: 0...max(player.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        wasPlayingBeforeScrub = player.isPlaying
                        player.pause()
                    } else if let target = scrubPosition {
                        player.seek(to: target)
                        scrubPosition = nil
                        if wasPlayingBeforeScrub { player.toggle() }
                    }
                }
            )
            .disabled(player.duration == 0)
            .accessibilityLabel(L10n.tr("Position"))
            .accessibilityValue(L10n.tr("Position %@ of %@", String(describing: RecordingTime.spoken(position)), String(describing: RecordingTime.spoken(player.duration))))
            Text(RecordingTime.clock(player.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
        }
    }
}
