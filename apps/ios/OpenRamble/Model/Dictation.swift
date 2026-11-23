import DictationCore
import Foundation
import LocalASR
import Observation
import UIKit

/// Recording a take and turning it into words.
///
/// One take records at a time; any number can be written behind it, one after
/// another. A take is in the store from the moment recording starts, so the
/// app being ended mid-sentence leaves its audio behind to be written on the
/// next launch rather than losing it.
@MainActor
@Observable
final class Dictation {
    enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
    }

    enum Notice: Hashable {
        case copied
        case microphoneDenied
        case message(String)
    }

    private(set) var phase: Phase = .idle
    /// The voice's loudness, newest last, sampled twenty times a second.
    private(set) var levels: [Float] = Array(repeating: 0, count: Dictation.levelCount)
    /// Takes whose words are being written right now.
    private(set) var writing: Set<Take.ID> = []
    private(set) var notice: Notice?
    /// Changes each time a take's words arrive, for the haptic.
    private(set) var wordsArrived = 0
    private(set) var isModelOpen = false

    /// Copy each take's words when they arrive, so they are ready to paste.
    var copiesEachTake: Bool {
        didSet { defaults.set(copiesEachTake, forKey: Self.copiesKey) }
    }

    let store: TakeStore
    private let writer: Writer
    private let recorder: any VoiceRecording
    private let liveActivity: LiveActivityController?
    private let defaults: UserDefaults
    private var current: Take?
    private var metering: Task<Void, Never>?
    private var noticeToken = 0

    static let levelCount = 56
    static let copiesKey = "copiesEachTake"
    /// Shorter than this is a tap, not a take.
    static let shortestTake: TimeInterval = 0.5

    init(
        store: TakeStore,
        writer: Writer,
        recorder: any VoiceRecording,
        liveActivity: LiveActivityController? = LiveActivityController(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.writer = writer
        self.recorder = recorder
        self.liveActivity = liveActivity
        self.defaults = defaults
        copiesEachTake = defaults.object(forKey: Self.copiesKey) as? Bool ?? true
        self.recorder.onInterruption = { [weak self] in
            Task { await self?.finish() }
        }
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// The take being recorded, which the list does not show yet.
    var recordingID: Take.ID? { current?.id }

    // MARK: - The model

    func modelBecameReady(at directory: URL) async {
        do {
            try await writer.prepare(modelDirectory: directory)
            isModelOpen = true
            await writeUnfinished()
        } catch {
            show(.message("The voice model could not be opened. Remove it in Settings and download it again."))
        }
    }

    func modelWasRemoved() async {
        isModelOpen = false
        await writer.unload()
    }

    // MARK: - Recording

    func toggle() async {
        switch phase {
        case .idle: await start()
        case .recording: await finish()
        case .starting: break
        }
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        let draft = Take(duration: 0, state: .writing)
        let url = store.newAudioURL(for: draft.id)
        do {
            try await recorder.start(to: url)
        } catch RecordingError.microphoneDenied {
            phase = .idle
            show(.microphoneDenied, for: nil)
            return
        } catch {
            phase = .idle
            show(.message("The microphone did not start. \(Self.describe(error))"))
            return
        }
        var take = draft
        take.audioFileName = url.lastPathComponent
        store.insert(take)
        current = take
        let since = Date.now
        phase = .recording(since: since)
        notice = nil
        liveActivity?.listening(since: since)
        startMetering()
        Task { await writer.warmUp() }
    }

    func finish() async {
        guard case .recording = phase, var take = current else { return }
        stopMetering()
        take.duration = recorder.stop()
        let stoppedAt = ContinuousClock.now
        current = nil
        phase = .idle
        guard take.duration >= Self.shortestTake else {
            store.delete(take.id)
            liveActivity?.cancel()
            show(.message("Too short to hear anything."))
            return
        }
        store.update(take)
        liveActivity?.writing(duration: take.duration)
        await write(take.id, since: stoppedAt)
    }

    /// Stops recording and throws the take away.
    func discard() {
        guard isRecording, let take = current else { return }
        stopMetering()
        recorder.discard()
        store.delete(take.id)
        current = nil
        phase = .idle
        liveActivity?.cancel()
    }

    // MARK: - Writing

    /// Writes a take's words: after recording, for a file, or again after a failure.
    func write(_ id: Take.ID, since stoppedAt: ContinuousClock.Instant = .now) async {
        guard var take = store.take(id), !writing.contains(id) else { return }
        guard let audio = store.audioURL(for: take) else {
            take.state = .failed("The recording is missing.")
            store.update(take)
            liveActivity?.failed(duration: take.duration)
            return
        }
        writing.insert(id)
        defer { writing.remove(id) }
        take.state = .writing
        store.update(take)

        // Writing finishes even if the person leaves the app straight away.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Writing a take")
        defer { UIApplication.shared.endBackgroundTask(background) }

        do {
            let words = try await writer.write(fileURL: audio)
            take.text = words.text
            take.state = words.text.isEmpty ? .silent : .written
            if take.duration == 0 { take.duration = words.audioDuration }
            take.writtenIn = Self.seconds(stoppedAt.duration(to: .now))
            store.update(take)
            let copied = take.hasWords && copiesEachTake && take.source == .microphone
            if copied {
                Clipboard.copy(take.text)
                show(.copied)
            }
            wordsArrived += 1
            liveActivity?.written(wordCount: Self.wordCount(take.text), copied: copied, duration: take.duration)
        } catch {
            take.state = .failed(Self.describe(error))
            store.update(take)
            liveActivity?.failed(duration: take.duration)
        }
    }

    /// Opens an audio file the person chose and writes it like a take.
    /// Returns the take as it ended, written or not.
    @discardableResult
    func open(file: URL) async -> Take? {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        var take = Take(duration: 0, state: .writing, source: .file)
        let ext = file.pathExtension.isEmpty ? "audio" : file.pathExtension.lowercased()
        let destination = store.newAudioURL(for: take.id, extension: ext)
        do {
            try FileManager.default.copyItem(at: file, to: destination)
        } catch {
            show(.message("That file could not be opened. \(Self.describe(error))"))
            return nil
        }
        take.audioFileName = destination.lastPathComponent
        store.insert(take)
        await write(take.id)
        return store.take(take.id)
    }

    func copy(_ take: Take) {
        guard take.hasWords else { return }
        Clipboard.copy(take.text)
        show(.copied)
    }

    private func writeUnfinished() async {
        for take in store.unfinished where take.id != current?.id {
            await write(take.id)
        }
    }

    // MARK: - Helpers

    private func startMetering() {
        metering?.cancel()
        metering = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var levels = self.levels
                levels.removeFirst()
                levels.append(self.recorder.level())
                self.levels = levels
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopMetering() {
        metering?.cancel()
        metering = nil
        levels = Array(repeating: 0, count: Self.levelCount)
    }

    private func show(_ notice: Notice, for seconds: Double? = 1.8) {
        self.notice = notice
        noticeToken += 1
        guard let seconds else { return }
        let token = noticeToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
        }
    }

    func dismissNotice() {
        notice = nil
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ASREngineError {
            switch error {
            case .unsupportedAudioFormat:
                return "This audio could not be read."
            case .modelsNotLoaded, .modelsUnavailable:
                return "The voice model is not open."
            case .cancelled:
                return "Writing was stopped."
            default:
                return "The words could not be written."
            }
        }
        if error is Writer.Failure { return "The voice model is not open yet." }
        if case let RecordingError.couldNotStart(reason) = error { return reason }
        return error.localizedDescription
    }
}
