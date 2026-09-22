@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import DictationAudio
import DictationCore
import Foundation
@preconcurrency import ScreenCaptureKit

/// Local screen capture for OpenRamble. ScreenCaptureKit supplies display
/// frames; the existing MeetingCapture supplies aligned 16 kHz audio through
/// `audioSink`, so WAV, transcription and AAC share one recording timeline.
@MainActor
public final class ScreenRecordingCapture: NSObject, ScreenRecordingCapturing, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let media = ScreenMediaState()
    private let sink: ScreenAudioSink
    private let directory: URL
    private(set) var options: ScreenRecordingOptions
    private let onFailure: @Sendable (String) -> Void
    private let onBubbleChange: @MainActor (ScreenRecordingOptions) -> Void

    private var display: SCDisplay?
    private var displayOptionName: String?
    private var stream: SCStream?
    private var cameraSession: AVCaptureSession?
    private var cameraQueue: DispatchQueue?
    private var overlay: CameraBubbleOverlay?
    private var prepared = false
    private var recording = false
    private var stopping = false

    public init(directory: URL,
         options: ScreenRecordingOptions,
         onFailure: @escaping @Sendable (String) -> Void = { _ in },
         onBubbleChange: @escaping @MainActor (ScreenRecordingOptions) -> Void = { _ in }) {
        self.directory = directory
        self.options = options
        self.onFailure = onFailure
        self.onBubbleChange = onBubbleChange
        sink = ScreenAudioSink(media: media)
        super.init()
    }

    public var audioSink: any MeetingAudioBlockSink { sink }
    public var outputURL: URL? { media.finishedURL }
    public var displayName: String? { displayOptionName }

    /// The static list used by the preflight panel. Names are intentionally
    /// display names only; no window titles or file names leave this layer.
    public static func displays() async throws -> [ScreenDisplayOption] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map { display in
            let name = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            })?.localizedName ?? "Display \(display.displayID)"
            return ScreenDisplayOption(id: display.displayID, name: name)
        }
    }

    public func prepare() async throws {
        guard !recording else { throw ScreenRecordingError.alreadyRecording }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let selectedID = options.displayID ?? mainDisplayID() ?? content.displays.first?.displayID
        guard let selectedID,
              let selected = content.displays.first(where: { $0.displayID == selectedID }) else {
            throw ScreenRecordingError.noDisplay
        }
        display = selected
        options.displayID = selected.displayID
        displayOptionName = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selected.displayID
        })?.localizedName ?? "Display \(selected.displayID)"

        if options.cameraEnabled {
            try await prepareCamera()
        }
        prepared = true
    }

    public func start() async throws {
        guard !recording else { throw ScreenRecordingError.alreadyRecording }
        if !prepared { try await prepare() }
        guard let display else { throw ScreenRecordingError.notPrepared }
        let size = ScreenBubbleGeometry.videoSize(width: display.width, height: display.height)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent("video.mp4.incomplete", isDirectory: false)
        try? FileManager.default.removeItem(at: temporaryURL)
        let writer = try ScreenMovieWriter(url: temporaryURL, width: size.width, height: size.height)
        media.configure(writer: writer, width: size.width, height: size.height,
                        scale: options.bubbleScale, position: options.bubblePosition,
                        cameraEnabled: options.cameraEnabled)
        media.setInitialAnchorIfNeeded()

        do {
            if options.cameraEnabled {
                try await showOverlay()
            }
            let current = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ownApps = current.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = size.width
            config.height = size.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 5
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.ignoreShadowsDisplay = true
            config.shouldBeOpaque = true
            // System audio is written from MeetingCapture's Core Audio tap so
            // it is aligned with the WAV and does not get captured a second time.
            config.capturesAudio = false
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: media.queue)
            stream = newStream
            media.setAccepting(true)
            try await newStream.startCapture()
            recording = true
        } catch {
            cleanupFailedStart()
            throw error
        }
    }

    public func pause() async throws {
        guard recording, let stream else { throw ScreenRecordingError.notRecording }
        media.setAccepting(false)
        try await stream.stopCapture()
        recording = false
    }

    public func resume() async throws {
        guard !recording, let stream else { throw ScreenRecordingError.notRecording }
        media.setAccepting(true)
        try await stream.startCapture()
        if options.cameraEnabled, overlay == nil {
            try await showOverlay()
        }
        recording = true
    }

    public func stop() async throws {
        guard (recording || stream != nil || prepared || cameraSession != nil), !stopping else {
            throw ScreenRecordingError.notRecording
        }
        stopping = true
        defer { stopping = false }
        recording = false
        media.setAccepting(false)
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
        hideOverlay()
        stopCamera()
        guard let writer = media.detachWriter() else {
            prepared = false
            return
        }
        do {
            try await writer.finish()
            let finalURL = directory.appendingPathComponent("video.mp4", isDirectory: false)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: writer.outputURL, to: finalURL)
            media.setFinishedURL(finalURL)
            prepared = false
        } catch {
            media.cancelWriter()
            prepared = false
            throw error
        }
    }

    public func updateCameraEnabled(_ enabled: Bool) async throws {
        guard options.cameraEnabled != enabled else { return }
        if enabled {
            do {
                try await prepareCamera()
                options.cameraEnabled = true
                media.setCameraEnabled(true)
                if recording || stream != nil || prepared { try await showOverlay() }
            } catch {
                stopCamera()
                throw error
            }
        } else {
            options.cameraEnabled = false
            media.setCameraEnabled(false)
            hideOverlay()
            stopCamera()
        }
        onBubbleChange(options)
    }

    public func updateBubbleScale(_ scale: Double) {
        options.bubbleScale = ScreenBubbleGeometry.clampedScale(scale)
        media.setBubble(scale: options.bubbleScale, position: options.bubblePosition)
        overlay?.updateScale(options.bubbleScale)
        onBubbleChange(options)
    }

    public func updateBubblePosition(_ position: NormalizedPoint) {
        options.bubblePosition = position
        media.setBubble(scale: options.bubbleScale, position: position)
        overlay?.updatePosition(position)
        onBubbleChange(options)
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let box = SendableSampleBuffer(sampleBuffer)
        media.queue.async { [media] in media.appendVideo(box.value) }
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        media.setAccepting(false)
        Task { @MainActor [weak self] in
            guard let self, !self.stopping else { return }
            self.recording = false
            self.onFailure(error.localizedDescription)
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    nonisolated public func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        media.setCameraBuffer(image)
    }

    private func prepareCamera() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw ScreenRecordingError.permissionDenied("Камера")
            }
        case .restricted:
            throw ScreenRecordingError.cameraRestricted
        case .denied:
            throw ScreenRecordingError.permissionDenied("Камера")
        @unknown default:
            throw ScreenRecordingError.permissionDenied("Камера")
        }
        if cameraSession != nil { return }
        guard let device = AVCaptureDevice.default(for: .video) else { throw ScreenRecordingError.cameraUnavailable }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw ScreenRecordingError.cameraUnavailable }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        let queue = DispatchQueue(label: "is.waiwai.openramble.camera", qos: .userInitiated)
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw ScreenRecordingError.cameraUnavailable }
        session.addOutput(output)
        session.commitConfiguration()
        cameraSession = session
        cameraQueue = queue
        let box = SendableCaptureSession(session)
        queue.async { box.value.startRunning() }
    }

    private func showOverlay() async throws {
        guard let session = cameraSession, let display else { throw ScreenRecordingError.cameraUnavailable }
        let overlay = CameraBubbleOverlay()
        try overlay.show(session: session,
                         displayID: display.displayID,
                         scale: options.bubbleScale,
                         position: options.bubblePosition) { [weak self] position, scale in
            guard let self else { return }
            self.options.bubblePosition = position
            self.options.bubbleScale = scale
            self.media.setBubble(scale: scale, position: position)
            self.onBubbleChange(self.options)
        }
        self.overlay = overlay
    }

    private func hideOverlay() {
        overlay?.hide()
        overlay = nil
    }

    private func stopCamera() {
        let session = cameraSession
        cameraSession = nil
        if let session {
            let box = SendableCaptureSession(session)
            cameraQueue?.async { box.value.stopRunning() }
        }
        cameraQueue = nil
        media.setCameraBuffer(nil)
    }

    private func cleanupFailedStart() {
        media.setAccepting(false)
        stream = nil
        hideOverlay()
        stopCamera()
        media.cancelWriter()
        prepared = false
    }

    private func mainDisplayID() -> UInt32? {
        let number = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value
    }
}

private final class ScreenMediaState: @unchecked Sendable {
    let queue = DispatchQueue(label: "is.waiwai.openramble.screen-media", qos: .userInitiated)
    private var writer: ScreenMovieWriter?
    private var compositor: ScreenFrameCompositor?
    private var accepting = false
    private var cameraEnabled = false
    private var cameraBuffer: CVPixelBuffer?
    private var scale = 0.20
    private var position = NormalizedPoint(x: 0.15, y: 0.82)
    private var anchorHost: UInt64?
    private var anchorFrame = 0
    private var firstHost: UInt64?
    private var fallbackFrame = 0
    private var firstVideoFrameWritten = false
    private var finished: URL?

    var finishedURL: URL? { queue.sync { finished } }

    func configure(writer: ScreenMovieWriter, width: Int, height: Int, scale: Double, position: NormalizedPoint, cameraEnabled: Bool) {
        queue.sync {
            self.writer = writer
            self.compositor = try? ScreenFrameCompositor(width: width, height: height)
            self.scale = ScreenBubbleGeometry.clampedScale(scale)
            self.position = position
            self.cameraEnabled = cameraEnabled
            // Audio may begin before ScreenCaptureKit starts. Keep accepting
            // aligned PCM immediately; `setAccepting` gates only video.
            self.accepting = true
            self.fallbackFrame = 0
            self.firstVideoFrameWritten = false
            self.firstHost = nil
            self.finished = nil
        }
    }

    func setInitialAnchorIfNeeded() {
        queue.sync {
            if anchorHost == nil {
                anchorHost = Self.hostNanoseconds()
                anchorFrame = 0
            }
        }
    }

    func anchor(hostNanoseconds: UInt64, frame: Int) {
        queue.async {
            self.anchorHost = hostNanoseconds
            self.anchorFrame = max(0, frame)
            self.firstHost = nil
            self.fallbackFrame = max(0, frame)
        }
    }

    func receiveAudio(microphone: [Float], system: [Float], startFrame: Int) {
        queue.async {
            guard let writer = self.writer else { return }
            _ = writer.appendAudio(microphone: microphone, system: system, startFrame: startFrame)
        }
    }

    func setAccepting(_ value: Bool) { queue.async { self.accepting = value } }
    func setCameraEnabled(_ value: Bool) { queue.async { self.cameraEnabled = value } }
    func setBubble(scale: Double, position: NormalizedPoint) {
        queue.async {
            self.scale = ScreenBubbleGeometry.clampedScale(scale)
            self.position = position
        }
    }
    func setCameraBuffer(_ buffer: CVPixelBuffer?) {
        let box = SendablePixelBuffer(buffer)
        queue.async { self.cameraBuffer = box.value }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard accepting,
              CMSampleBufferIsValid(sampleBuffer),
              let image = CMSampleBufferGetImageBuffer(sampleBuffer),
              let writer,
              let compositor else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = Self.hostNanoseconds(timestamp)
        let frameTime: CMTime
        if let host, let anchorHost {
            let delta = max(Int64.min / 2, Int64(bitPattern: host) - Int64(bitPattern: anchorHost))
            let frames = anchorFrame + Int((Double(delta) / 1_000_000_000 * 16_000).rounded())
            frameTime = CMTime(value: CMTimeValue(max(0, frames)), timescale: 16_000)
        } else {
            let frames = fallbackFrame
            fallbackFrame += 533
            frameTime = CMTime(value: CMTimeValue(max(0, frames)), timescale: 16_000)
        }
        guard let output = compositor.frame(screen: image,
                                            camera: cameraEnabled ? cameraBuffer : nil,
                                            scale: scale,
                                            position: position) else { return }
        // ScreenCaptureKit may deliver its first frame a few hundred
        // milliseconds after the audio clock starts. Present that real first
        // frame at t=0 instead of leaving an artificial black opening in the
        // movie; later frames keep their aligned timestamps.
        let presentationTime = firstVideoFrameWritten ? frameTime : .zero
        firstVideoFrameWritten = true
        _ = writer.appendVideo(output, at: presentationTime)
    }

    func detachWriter() -> ScreenMovieWriter? {
        queue.sync {
            accepting = false
            let result = writer
            writer = nil
            compositor = nil
            return result
        }
    }

    func cancelWriter() { queue.sync { writer?.cancel(); writer = nil; compositor = nil } }
    func setFinishedURL(_ url: URL) { queue.sync { self.finished = url } }

    private static func hostNanoseconds(_ time: CMTime? = nil) -> UInt64? {
        if time == nil {
            return UInt64(max(0, AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000))
        }
        guard let time else { return nil }
        guard time.isValid else { return nil }
        let converted = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .quickTime)
        guard converted.isValid, converted.value >= 0 else { return nil }
        return UInt64(converted.value)
    }
}

private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer?
    init(_ value: CVPixelBuffer?) { self.value = value }
}

private struct SendableCaptureSession: @unchecked Sendable {
    let value: AVCaptureSession
    init(_ value: AVCaptureSession) { self.value = value }
}

private final class ScreenAudioSink: MeetingAudioBlockSink, @unchecked Sendable {
    private let media: ScreenMediaState
    init(media: ScreenMediaState) { self.media = media }
    func receive(microphone: [Float], system: [Float], startFrame: Int) {
        media.receiveAudio(microphone: microphone, system: system, startFrame: startFrame)
    }
    func anchor(hostNanoseconds: UInt64, frame: Int) {
        media.anchor(hostNanoseconds: hostNanoseconds, frame: frame)
    }
}
