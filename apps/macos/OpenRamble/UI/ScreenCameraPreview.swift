import AVFoundation
import AppKit
import DictationCore
import SwiftUI

/// A small live stage for the setup sheet. The person adjusts the bubble by
/// looking at it, rather than translating a camera size into a percentage.
struct ScreenCameraPreview: View {
    let cameraAvailable: Bool
    let bubbleScale: Double
    let bubblePosition: NormalizedPoint

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let diameter = min(size.width, size.height) * ScreenBubbleGeometry.clampedScale(bubbleScale)
            let x = min(max(bubblePosition.x * size.width, diameter / 2), size.width - diameter / 2)
            let y = min(max(bubblePosition.y * size.height, diameter / 2), size.height - diameter / 2)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black)
                    .overlay {
                        VStack(spacing: 5) {
                            Image(systemName: "rectangle.inset.filled")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.36))
                            Text("Your display")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.42))
                        }
                    }

                if cameraAvailable {
                    CameraPreviewSurface()
                        .frame(width: diameter, height: diameter)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.82), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .position(x: x, y: y)
                        .animation(.easeOut(duration: 0.12), value: diameter)
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .overlay {
                            Image(systemName: "video.slash")
                                .foregroundStyle(.white.opacity(0.66))
                        }
                        .frame(width: diameter, height: diameter)
                        .position(x: x, y: y)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cameraAvailable ? "Live camera bubble preview" : "Camera preview unavailable")
    }
}

/// Owns a short-lived camera session for the setup sheet. The recording
/// creates its own session after the sheet closes, so the preview cannot leak
/// into the saved movie or hold the camera while the person is not configuring.
private struct CameraPreviewSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraPreviewNSView { CameraPreviewNSView() }

    func updateNSView(_ view: CameraPreviewNSView, context: Context) {
        view.startIfNeeded()
    }

    static func dismantleNSView(_ view: CameraPreviewNSView, coordinator: ()) {
        view.stop()
    }
}

private final class CameraPreviewNSView: NSView {
    private let sessionBox = CameraPreviewSessionBox()
    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: sessionBox.session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return layer
    }()
    private var configured = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    func startIfNeeded() {
        sessionBox.start()
    }

    func stop() {
        sessionBox.stop()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        layer?.cornerRadius = bounds.width / 2
        CATransaction.commit()
    }
}

/// AVCaptureSession is an Objective-C reference object whose lifecycle is
/// deliberately confined to this serial queue. The box keeps that boundary
/// explicit so the AppKit view can remain main-actor isolated under Swift 6.
private final class CameraPreviewSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "is.waiwai.openramble.camera-preview", qos: .userInitiated)
    private var configured = false

    func start() {
        queue.async { [self] in
            if !configured {
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else { return }
                session.beginConfiguration()
                session.sessionPreset = .high
                session.addInput(input)
                session.commitConfiguration()
                configured = true
            }
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}
