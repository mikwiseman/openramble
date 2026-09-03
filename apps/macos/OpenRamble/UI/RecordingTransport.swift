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
        VStack(spacing: GlassTokens.Space.inline) {
            HStack(spacing: GlassTokens.Space.inline) {
                Text(RecordingTime.clock(position))
                    .font(.system(size: GlassTokens.Label.footnote))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { position },
                        set: { scrubPosition = $0 }
                    ),
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
                .accessibilityLabel("Position")
                .accessibilityValue("\(RecordingTime.spoken(position)) of \(RecordingTime.spoken(player.duration))")
                Text(RecordingTime.clock(player.duration))
                    .font(.system(size: GlassTokens.Label.footnote))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            HStack(spacing: GlassTokens.Space.section) {
                Button { player.skip(by: -RecordingPlayer.skipInterval) } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }
                .accessibilityLabel("Skip back 15 seconds")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(by: RecordingPlayer.skipInterval) } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }
                .accessibilityLabel("Skip forward 15 seconds")
            }
            .buttonStyle(.borderless)
            .disabled(player.duration == 0)
        }
    }
}
