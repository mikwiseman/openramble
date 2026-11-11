import DictationAudio
import DictationCore
import Foundation
import LocalASR

/// Audio and video files brought into the Library, and their transcripts.
///
/// An imported file becomes a recording like any other: its audio is copied
/// into the recordings store in the store's own format, so it plays, shows a
/// waveform, exports and is deleted exactly as a voice note is. The original
/// file is only read.
///
/// **An engine of its own.** A file is transcribed by a second recognizer,
/// never the one dictation uses. A file takes minutes, and for all of them
/// the dictation engine would otherwise be either busy or, for a file in the
/// other model's language, loaded with a model the next dictation cannot use.
/// Kept apart, nothing here can change which model a dictation gets, when it
/// is loaded, or when it rests. The cost is one more model in memory while a
/// file is read, given back when the last one is done. Two models side by
/// side were run in one process before this was built: in turn and at the
/// same moment, each gave its own text.
///
/// **One at a time, dictation first.** Files are transcribed in the order
/// they came, and a piece does not start while a dictation is running.
///
/// **A quit loses nothing.** A recording marks itself as an import until its
/// transcript is whole, and the audio is already in the store, so the next
/// launch takes it up again from the start.
@MainActor
final class RecordingImporter {
    /// What the importer is doing, for the Library to show.
    struct Activity: Equatable {
        /// Files being read into the Library. They have no row yet.
        var copying = 0
        /// The recording being transcribed, and how far it has got.
        var transcribing: UUID?
        var fraction = 0.0
        /// Imported recordings whose turn has not come, in order.
        var waiting: [UUID] = []
        /// The first waiting recording needs a speech model that is not ready.
        var needsModel = false

        var isIdle: Bool { copying == 0 && transcribing == nil && waiting.isEmpty }
    }

    /// Why a file could not be brought in.
    enum Failure: Error, Equatable {
        /// Not audio or video this Mac can decode.
        case unreadable
        /// It decodes, and there is no sound in it at all.
        case empty
        /// The Library could not keep it: the disk, most likely.
        case cannotStore
    }

    struct Edges {
        var store: MeetingStore
        /// The importer's own engine. One instance for its whole life, so
        /// whoever ends the app can unload it.
        var recognizer: any DictationRecognizing
        /// The folder of the model that reads this language, once it is ready.
        var modelDirectory: @MainActor (RecordingImportLanguage) -> URL?
        /// The same dictionary and typography as a recording gets.
        var makePipeline: @MainActor () -> any TextProcessing
        var arbiter: EngineArbiter
        var now: @Sendable () -> Date = { Date() }
    }

    /// Three pieces in a row that will not decode are the engine, not the
    /// audio: stop and say the transcript is not whole.
    static let failuresBeforeStop = 3

    private(set) var activity = Activity() {
        didSet { if oldValue != activity { onActivity(activity) } }
    }

    var onActivity: (Activity) -> Void = { _ in }
    /// A file is in the Library, with its audio and no transcript yet.
    var onImported: (MeetingRecordingMetadata) -> Void = { _ in }
    /// The transcript so far, after every piece.
    var onTranscript: (UUID, [MeetingUtterance]) -> Void = { _, _ in }
    /// Transcription ended and the recording says how on disk.
    var onFinished: (UUID) -> Void = { _ in }
    /// A file could not be brought in. The name is for the notice only.
    var onFailure: (Failure, _ name: String) -> Void = { _, _ in }

    private struct Job: Equatable {
        let id: UUID
        let language: RecordingImportLanguage
    }

    private let edges: Edges
    private var queue: [Job] = []
    private var cancelled: Set<UUID> = []
    private var copying: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var loadedDirectory: URL?
    private var isStopping = false

    init(edges: Edges) {
        self.edges = edges
    }

    // MARK: - Bringing files in

    /// Copy these files into the Library and queue their transcripts.
    func add(_ files: [URL], language: RecordingImportLanguage) {
        guard !files.isEmpty, !isStopping else { return }
        activity.copying += files.count
        let previous = copying
        copying = Task { [weak self] in
            await previous?.value
            for file in files {
                guard let self else { return }
                await self.bringIn(file, language: language)
            }
        }
    }

    private func bringIn(_ file: URL, language: RecordingImportLanguage) async {
        defer { activity.copying -= 1 }
        let name = file.deletingPathExtension().lastPathComponent
        do {
            let metadata = try await Self.store(file: file, language: language, in: edges.store, now: edges.now())
            onImported(metadata)
            enqueue(Job(id: metadata.id, language: language))
        } catch let failure as Failure {
            onFailure(failure, name)
        } catch {
            onFailure(.cannotStore, name)
        }
    }

    /// Take up the imports an earlier run did not finish.
    func resume(_ recordings: [MeetingRecordingMetadata]) {
        Self.removeHalfCopies(in: edges.store)
        let unfinished = recordings
            .filter { recording in
                guard recording.isImported,
                      recording.transcriptionState == .live || recording.transcriptionState == .waitingForModel
                else { return false }
                // The copy the pieces are read from. Without it there is
                // nothing left to transcribe from.
                return edges.store.rawAudioURL(for: recording.id) != nil
            }
            .sorted { $0.startedAt < $1.startedAt }
        for recording in unfinished {
            enqueue(Job(id: recording.id, language: recording.importLanguage ?? .automatic))
        }
    }

    /// A model became ready, or stopped being: look at the queue again.
    func modelsChanged() {
        refreshWaiting()
        startWorkerIfNeeded()
    }

    /// The recording is going away. Its transcript is no longer wanted.
    func cancel(_ id: UUID) {
        if queue.contains(where: { $0.id == id }) {
            queue.removeAll { $0.id == id }
            refreshWaiting()
        } else if activity.transcribing == id {
            cancelled.insert(id)
        }
    }

    /// The app is ending. Nothing more is written, so what is unfinished
    /// stays marked as unfinished and is taken up at the next launch.
    func stop() {
        isStopping = true
    }

    // MARK: - The queue

    private func enqueue(_ job: Job) {
        guard !queue.contains(job), activity.transcribing != job.id else { return }
        queue.append(job)
        refreshWaiting()
        startWorkerIfNeeded()
    }

    private func refreshWaiting() {
        activity.waiting = queue.map(\.id)
        activity.needsModel = !queue.isEmpty && nextRunnable() == nil
    }

    private func nextRunnable() -> Job? {
        queue.first { edges.modelDirectory($0.language) != nil }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !isStopping, nextRunnable() != nil else { return }
        worker = Task { [weak self] in
            await self?.work()
        }
    }

    private func work() async {
        defer { worker = nil }
        repeat {
            while !isStopping, let job = nextRunnable(), let directory = edges.modelDirectory(job.language) {
                queue.removeAll { $0 == job }
                activity.transcribing = job.id
                activity.fraction = 0
                refreshWaiting()
                await transcribe(job, modelDirectory: directory)
                cancelled.remove(job.id)
                activity.transcribing = nil
                activity.fraction = 0
                refreshWaiting()
            }
            // Nothing left that can run: give the model's memory back.
            await edges.recognizer.unload()
            loadedDirectory = nil
            // A file may have arrived while the engine was unloading.
        } while !isStopping && nextRunnable() != nil
    }

    // MARK: - One transcript

    private func transcribe(_ job: Job, modelDirectory: URL) async {
        let store = edges.store
        guard let audio = store.rawAudioURL(for: job.id) else {
            finish(job, as: .failed)
            return
        }
        let pieces: [Range<Int>]
        do {
            if loadedDirectory != modelDirectory {
                await edges.recognizer.unload()
                loadedDirectory = nil
                try await edges.recognizer.prepare(modelDirectory: modelDirectory)
                loadedDirectory = modelDirectory
            }
            pieces = try await Self.plan(audio: audio)
        } catch {
            finish(job, as: .failed)
            return
        }

        let recognizer = edges.recognizer
        let pipeline = edges.makePipeline()
        let reader = MeetingPCMWindowReader(url: audio)
        let rate = Double(MeetingWriter.sampleRate)
        let total = max(1, pieces.reduce(0) { $0 + $1.count })
        var assembler = MeetingUtteranceAssembler()
        var closed: [MeetingUtterance] = []
        var done = 0
        var failuresInARow = 0

        for piece in pieces {
            await edges.arbiter.awaitDictationEnd()
            guard !isStopping, !cancelled.contains(job.id) else { return }
            let segment = MeetingSegmentRef(channel: .microphone, startFrame: piece.lowerBound, frameCount: piece.count)
            let start = Double(piece.lowerBound) / rate
            let end = Double(piece.upperBound) / rate
            let decoded: MeetingUtteranceAssembler.Segment
            do {
                let text = try await Self.decode(segment, reader: reader, recognizer: recognizer)
                decoded = .init(channel: .microphone, start: start, end: end, text: pipeline.run(text).output.text)
                failuresInARow = 0
            } catch {
                decoded = .init(channel: .microphone, start: start, end: end, text: "", isFailed: true)
                failuresInARow += 1
            }
            // The engine was unloaded under the decode, or the recording was
            // moved to the Trash while it ran: not this piece's failure.
            guard !isStopping, !cancelled.contains(job.id) else { return }
            closed += assembler.append(decoded)
            done += piece.count
            let soFar = closed + (assembler.pending.map { [$0] } ?? [])
            try? store.write(
                MeetingTranscript(utterances: soFar, decodedFrames: [.microphone: piece.upperBound]),
                for: job.id
            )
            onTranscript(job.id, soFar)
            activity.fraction = Double(done) / Double(total)
            if failuresInARow >= Self.failuresBeforeStop {
                finish(job, as: .partial)
                return
            }
        }
        closed += assembler.flush()
        try? store.write(
            MeetingTranscript(utterances: closed, decodedFrames: [.microphone: pieces.last?.upperBound ?? 0]),
            for: job.id
        )
        onTranscript(job.id, closed)
        finish(job, as: .complete)
    }

    private func finish(_ job: Job, as state: MeetingTranscriptionState) {
        guard !isStopping, !cancelled.contains(job.id) else { return }
        if var metadata = edges.store.metadata(for: job.id) {
            metadata.transcriptionState = state
            try? edges.store.write(metadata)
        }
        onFinished(job.id)
    }

    // MARK: - Off the main thread

    /// Copy a file's sound into the store as a published recording.
    ///
    /// Mono at 16 kHz on the first channel, silence on the second: the shape
    /// of a voice note, which is what a file with one stream of sound is.
    nonisolated static func store(
        file: URL,
        language: RecordingImportLanguage,
        in store: MeetingStore,
        now: Date
    ) async throws -> MeetingRecordingMetadata {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }

        let stream: AudioFileStream
        do {
            stream = try await AudioFileStream(url: file)
        } catch AudioFileReader.Failure.emptyFile {
            throw Failure.empty
        } catch {
            throw Failure.unreadable
        }

        let id = UUID()
        // Copied under a name the store's crash recovery does not read. A
        // quit in the middle of a copy would otherwise come back at the next
        // launch as an untitled recording of half the file. The file itself
        // is untouched, so a half copy is simply dropped.
        let directory = copyDirectory(for: id, in: store)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let writer = MeetingWriter(directory: directory)
            try writer.open()
            while true {
                let block: [Float]
                do {
                    block = try await stream.read(frames: MeetingWriter.sampleRate)
                } catch {
                    throw Failure.unreadable
                }
                if block.isEmpty { break }
                try writer.append(microphone: block, system: [Float](repeating: 0, count: block.count))
            }
            try writer.finish()
            guard writer.frameCount > 0 else { throw Failure.empty }

            let name = file.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let metadata = MeetingRecordingMetadata(
                id: id,
                startedAt: now,
                duration: writer.duration,
                title: name.isEmpty ? nil : name,
                systemAudio: SystemAudioSummary(wasRequested: false),
                endReason: .stoppedByUser,
                transcriptionState: .live,
                importLanguage: language
            )
            // Whole now: it takes the store's own path into the list.
            try FileManager.default.moveItem(at: directory, to: store.incompleteDirectory(for: id))
            try store.write(metadata, incomplete: true)
            try store.publish(id)
            return metadata
        } catch {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: store.incompleteDirectory(for: id))
            throw (error as? Failure) ?? Failure.cannotStore
        }
    }

    nonisolated static let copyPrefix = "import-"

    nonisolated static func copyDirectory(for id: UUID, in store: MeetingStore) -> URL {
        store.incompleteRoot.appending(path: copyPrefix + id.uuidString, directoryHint: .isDirectory)
    }

    /// Copies a quit cut short. Nothing reads them, so they only take space.
    nonisolated static func removeHalfCopies(in store: MeetingStore) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: store.incompleteRoot, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(copyPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Where the stored audio is cut for the engine.
    nonisolated static func plan(audio: URL) async throws -> [Range<Int>] {
        let frames = MeetingWriter.frameCount(at: audio)
        let reader = MeetingPCMWindowReader(url: audio)
        var planner = FilePiecePlanner()
        var position = 0
        while position < frames {
            try Task.checkCancellation()
            let count = min(MeetingWriter.sampleRate * 4, frames - position)
            planner.push(try reader.read(channel: .microphone, startFrame: position, frameCount: count))
            position += count
        }
        return planner.finish()
    }

    private nonisolated static func decode(
        _ segment: MeetingSegmentRef,
        reader: MeetingPCMWindowReader,
        recognizer: any DictationRecognizing
    ) async throws -> String {
        let samples = try reader.read(segment)
        return try await recognizer.transcribe(samples: samples).text
    }
}
