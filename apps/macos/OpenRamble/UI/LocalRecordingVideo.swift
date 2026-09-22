import AVFoundation
import SwiftUI

/// A deliberately small AVPlayerLayer wrapper. The library owns transport
/// controls; putting another control bar inside the movie makes the same play
/// action mean two different things and exposes no useful extra capability.
struct LocalRecordingVideo: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.player = player
        view.primeFirstFrame()
    }
}

final class PlayerLayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    var player: AVPlayer? {
        didSet {
            guard oldValue !== player else { return }
            didPrimeFirstFrame = false
            playerLayer.player = player
        }
    }

    private var didPrimeFirstFrame = false

    /// AVPlayerLayer stays black until it receives a decoded sample. The
    /// player is often loaded just before SwiftUI attaches this view, so the
    /// controller's initial seek can happen too early. Repeat that harmless
    /// zero-time seek after the layer has a real output attached.
    func primeFirstFrame() {
        guard !didPrimeFirstFrame, let player else { return }
        didPrimeFirstFrame = true
        DispatchQueue.main.async {
            Task { @MainActor in
                player.pause()
                _ = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private var playerLayer: AVPlayerLayer {
        if let layer = layer as? AVPlayerLayer { return layer }
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        self.layer = layer
        return layer
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

struct LocalRecordingVideoPlaceholder: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: GlassTokens.Space.inline) {
            Image(systemName: "video.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(GlassTokens.Space.section)
        .contentSurface(RoundedRectangle(cornerRadius: GlassTokens.Radius.surface, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
