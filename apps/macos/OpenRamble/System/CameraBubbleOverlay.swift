import AppKit
import AVFoundation
import DictationCore

/// A single camera session drives both this preview and the compositor. The
/// panel never becomes key and follows the selected display across Spaces.
@MainActor
final class CameraBubbleOverlay: NSObject, NSWindowDelegate {
    private var panel: CameraBubblePanel?
    private var preview: CameraBubbleView?
    private var displayFrame = CGRect.zero
    private var usableFrame = CGRect.zero
    private var scale = 0.20
    private var position = NormalizedPoint(x: 0.15, y: 0.82)
    private var isApplyingFrame = false
    private var onChange: ((NormalizedPoint, Double) -> Void)?

    func show(session: AVCaptureSession,
              displayID: UInt32,
              scale: Double,
              position: NormalizedPoint,
              onChange: @escaping (NormalizedPoint, Double) -> Void) throws {
        hide()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { throw ScreenRecordingError.noDisplay }
        displayFrame = screen.frame
        usableFrame = screen.visibleFrame
        self.scale = ScreenBubbleGeometry.clampedScale(scale)
        self.position = ScreenBubbleGeometry.clampedPosition(position, scale: self.scale, in: displayFrame.size)
        self.onChange = onChange

        let view = CameraBubbleView(session: session) { [weak self] event in
            self?.handle(event)
        }
        let panel = CameraBubblePanel(contentRect: .zero,
                                      styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                      backing: .buffered,
                                      defer: false)
        panel.title = "OpenRamble · Камера"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentMinSize = NSSize(width: 80, height: 80)
        panel.contentMaxSize = NSSize(width: min(displayFrame.width, displayFrame.height) * 0.5,
                                      height: min(displayFrame.width, displayFrame.height) * 0.5)
        panel.contentView = view
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        self.panel = panel
        preview = view
        updateFrame()
        panel.orderFrontRegardless()
    }

    func updateScale(_ value: Double) {
        scale = ScreenBubbleGeometry.clampedScale(value)
        position = ScreenBubbleGeometry.clampedPosition(position, scale: scale, in: displayFrame.size)
        updateFrame()
    }

    func updatePosition(_ value: NormalizedPoint) {
        position = ScreenBubbleGeometry.clampedPosition(value, scale: scale, in: displayFrame.size)
        updateFrame()
    }

    func hide() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        preview?.disconnect()
        panel?.contentView = nil
        panel = nil
        preview = nil
        onChange = nil
    }

    func windowDidMove(_ notification: Notification) { emitCurrentFrame() }
    func windowDidResize(_ notification: Notification) { emitCurrentFrame() }

    private func updateFrame() {
        guard panel != nil else { return }
        let rect = ScreenBubbleGeometry.rect(in: displayFrame.size, scale: scale, position: position)
        let frame = clamped(rect.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY))
        apply(frame: frame)
    }

    private func handle(_ event: CameraBubbleView.Interaction) {
        switch event {
        case let .frame(frame): apply(frame: clamped(frame))
        }
    }

    private func emitCurrentFrame() {
        guard !isApplyingFrame, let panel else { return }
        let frame = clamped(panel.frame)
        position = ScreenBubbleGeometry.position(for: frame, in: displayFrame)
        onChange?(position, scale)
    }

    private func apply(frame: CGRect) {
        guard let panel else { return }
        isApplyingFrame = true
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        isApplyingFrame = false
        position = ScreenBubbleGeometry.position(for: frame, in: displayFrame)
        onChange?(position, scale)
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        let bounds = usableFrame.insetBy(dx: 8, dy: 8)
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }
}

private final class CameraBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CameraBubbleView: NSView {
    enum Interaction { case frame(CGRect) }

    private let previewLayer: AVCaptureVideoPreviewLayer
    private let onInteraction: (Interaction) -> Void
    private var resizing = false
    private var initialFrame = CGRect.zero
    private var initialPoint = NSPoint.zero

    init(session: AVCaptureSession, onInteraction: @escaping (Interaction) -> Void) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        self.onInteraction = onInteraction
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1.5
        previewLayer.videoGravity = .resizeAspectFill
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            // A self-view is mirrored while recording and in the saved movie,
            // matching the spatial cue people already know from Zoom and
            // FaceTime. Text on the screen remains unaffected.
            connection.isVideoMirrored = true
        }
        layer?.addSublayer(previewLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Кружок камеры. Перетащите, чтобы переместить или изменить размер.")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.width / 2
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        initialFrame = window?.frame ?? .zero
        initialPoint = event.locationInWindow
        resizing = bounds.insetBy(dx: -14, dy: -14).contains(convert(event.locationInWindow, from: nil))
            && convert(event.locationInWindow, from: nil).x > bounds.maxX - 24
            && convert(event.locationInWindow, from: nil).y < 24
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        if resizing {
            let delta = CGPoint(x: event.locationInWindow.x - initialPoint.x,
                                y: initialPoint.y - event.locationInWindow.y)
            let size = max(80, initialFrame.width + delta.x)
            let frame = CGRect(x: initialFrame.maxX - size, y: initialFrame.minY,
                               width: size, height: size)
            window.setFrame(frame, display: true)
            onInteraction(.frame(frame))
        } else {
            window.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        resizing = false
        NSCursor.pop()
    }

    func disconnect() { previewLayer.session = nil }
}
