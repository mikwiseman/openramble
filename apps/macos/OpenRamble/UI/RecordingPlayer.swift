import AVFoundation
import Foundation

/// Streams the original recording through a mono mixer. The file separates
/// microphone and system audio for recognition, not for left and right ears.
@MainActor
final class RecordingPlayer: ObservableObject {
    @Published private(set) var loadedID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var failedToLoad = false
    @Published private(set) var videoFailedToLoad = false
    @Published private(set) var videoPlayer: AVPlayer?

    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let monoMixer = AVAudioMixerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var scheduleID = UUID()
    private var tick: Timer?
    private var videoTimeObserver: Any?
    nonisolated(unsafe) private var configurationObserver: NSObjectProtocol?

    static let skipInterval: TimeInterval = 15

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(player)
        engine.attach(monoMixer)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Loading the same recording does not reset its position. AVAudioFile
    /// reads only the header here; even a long meeting starts without making
    /// another file or loading the recording into memory.
    func load(id: UUID, url: URL?, videoURL: URL? = nil) {
        guard loadedID != id else { return }
        unload()
        loadedID = id
        loadAudio(url)
        if let videoURL {
            loadVideo(id: id, url: videoURL)
        }
    }

    func unload() {
        stopTicking()
        scheduleID = UUID()
        player.stop()
        engine.stop()
        if let videoTimeObserver, let videoPlayer {
            videoPlayer.removeTimeObserver(videoTimeObserver)
        }
        videoTimeObserver = nil
        videoPlayer?.pause()
        videoPlayer = nil
        file = nil
        loadedID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        failedToLoad = false
        videoFailedToLoad = false
    }

    func toggle() {
        guard file != nil || videoPlayer != nil else { return }
        if isPlaying {
            pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            if videoPlayer != nil { playVideo() } else { playAudio() }
        }
    }

    func pause() {
        guard isPlaying else { return }
        if videoPlayer != nil {
            updateVideoTime()
            videoPlayer?.pause()
        } else {
            updateTime()
            player.pause()
            engine.pause()
        }
        isPlaying = false
        stopTicking()
    }

    func seek(to time: TimeInterval) {
        guard file != nil || videoPlayer != nil else { return }
        if videoPlayer != nil {
            let target = max(0, min(duration, time))
            videoPlayer?.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.currentTime = target
                }
            }
            currentTime = max(0, min(duration, time))
            let resume = isPlaying
            isPlaying = false
            stopTicking()
            if resume, currentTime < duration { playVideo() }
            return
        }
        let resume = isPlaying
        schedule(from: time)
        isPlaying = false
        stopTicking()
        if resume, currentTime < duration { play() }
        else { engine.pause() }
    }

    func skip(by seconds: TimeInterval) {
        if isPlaying { updateTime() }
        seek(to: currentTime + seconds)
    }

    private func play() {
        playAudio()
    }

    private func playAudio() {
        do {
            if !engine.isRunning { try engine.start() }
            player.play()
            failedToLoad = false
            isPlaying = true
            startTicking()
        } catch {
            failedToLoad = true
            isPlaying = false
            stopTicking()
        }
    }

    private func playVideo() {
        guard let videoPlayer else { return }
        videoPlayer.play()
        failedToLoad = false
        isPlaying = true
        startTicking()
    }

    private func loadAudio(_ url: URL?) {
        guard let url, let file = try? AVAudioFile(forReading: url), file.length > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1)
        else {
            failedToLoad = true
            return
        }
        self.file = file
        engine.connect(player, to: monoMixer, format: file.processingFormat)
        engine.connect(monoMixer, to: engine.mainMixerNode, format: mono)
        // Core Audio uses equal-power gains when downmixing stereo. Leave
        // enough headroom for two simultaneous full-scale voices.
        monoMixer.outputVolume = file.processingFormat.channelCount == 2 ? sqrt(0.5) : 1
        // Leave the main mixer's output format to macOS so it follows a
        // change between speakers and headphones.
        duration = Double(file.length) / file.processingFormat.sampleRate
        schedule(from: 0)
    }

    private func loadVideo(id: UUID, url: URL) {
        guard let asset = try? LocalRecordingAsset.make(url: url) else {
            videoFailedToLoad = true
            return
        }
        let item = AVPlayerItem(asset: asset)
        let video = AVPlayer(playerItem: item)
        video.actionAtItemEnd = .pause
        videoPlayer = video
        videoTimeObserver = video.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak video] time in
            guard video != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.loadedID == id else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
            }
        }
        Task { @MainActor [weak self, weak video] in
            guard let self, self.loadedID == id, let video else { return }
            let loadedDuration = try? await asset.load(.duration)
            guard self.loadedID == id else { return }
            if let loadedDuration, loadedDuration.seconds.isFinite, loadedDuration.seconds > 0 {
                self.duration = loadedDuration.seconds
                // A screen take uses the muxed movie as its one playback
                // source. Keep the WAV around for transcription and export,
                // but do not route it through a second audio graph.
                self.file = nil
                self.engine.stop()
                self.currentTime = 0
                self.videoPlayer = video
            } else {
                self.videoFailedToLoad = true
                self.videoPlayer = nil
            }
        }
    }

    private func schedule(from time: TimeInterval) {
        guard let file else { return }
        let id = UUID()
        scheduleID = id
        player.stop()
        startFrame = AVAudioFramePosition(max(0, min(duration, time)) * file.processingFormat.sampleRate)
        currentTime = Double(startFrame) / file.processingFormat.sampleRate
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        player.scheduleSegment(
            file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining),
            at: nil, completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Stop, seek and loading another file also complete an old
                // schedule. Only the one still playing may finish the UI.
                guard let self, self.scheduleID == id else { return }
                self.currentTime = self.duration
                self.isPlaying = false
                self.stopTicking()
                self.engine.pause()
            }
        }
    }

    private func updateTime() {
        guard let file, let renderTime = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: renderTime) else { return }
        currentTime = min(duration, Double(startFrame) / file.processingFormat.sampleRate
            + Double(time.sampleTime) / time.sampleRate)
    }

    private func outputChanged() {
        guard videoPlayer == nil else { return }
        guard file != nil else { return }
        let resume = isPlaying
        // Configuration changes stop the engine and clear scheduled audio.
        // Restore the schedule even while paused so the next Play has audio.
        schedule(from: currentTime)
        if resume { play() }
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.videoPlayer != nil { self.updateVideoTime() } else { self.updateTime() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    private func updateVideoTime() {
        guard let time = videoPlayer?.currentTime().seconds, time.isFinite else { return }
        currentTime = min(duration, max(0, time))
        if duration > 0, currentTime >= duration - 0.05 {
            isPlaying = false
            stopTicking()
        }
    }
}
