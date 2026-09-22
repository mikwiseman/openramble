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
            playerLayer.player = player
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
