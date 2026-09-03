import AVFoundation
import Foundation

/// Playback for the Recordings window: one recording at a time, with a
/// position that can be read and moved.
///
/// `HistoryAudioPlayer` plays and stops and nothing else, which is all a
/// two-second dictation needs. An hour-long meeting needs a scrubber and a
/// transcript that follows, so this one publishes `currentTime` and accepts
/// a seek. The tick is a plain timer in the window — the rule that forbids
/// timers applies to the menu bar label, which must cost nothing at rest,
/// not to a player someone is looking at.
@MainActor
final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var loadedID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// Playback could not start: the file is unreadable.
    @Published private(set) var failedToLoad = false

    private var player: AVAudioPlayer?
    private var tick: Timer?

    static let skipInterval: TimeInterval = 15

    /// Prepare `url` for the recording `id`. Loading the same id again is a
    /// no-op so a re-rendered view does not restart playback.
    func load(id: UUID, url: URL?) {
        guard loadedID != id else { return }
        unload()
        loadedID = id
        guard let url else {
            failedToLoad = true
            return
        }
        guard let created = try? AVAudioPlayer(contentsOf: url) else {
            failedToLoad = true
            return
        }
        created.delegate = self
        created.prepareToPlay()
        player = created
        duration = created.duration
        failedToLoad = false
    }

    func unload() {
        stopTicking()
        player?.stop()
        player = nil
        loadedID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        failedToLoad = false
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTicking()
        } else {
            // At the very end, Play means "from the start" — the alternative is
            // a button that does nothing.
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
            isPlaying = true
            startTicking()
        }
        currentTime = player.currentTime
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPlaying = false
        stopTicking()
        currentTime = player.currentTime
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(player.duration, time))
        player.currentTime = clamped
        currentTime = clamped
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.stopTicking()
            self.currentTime = self.duration
        }
    }
}
