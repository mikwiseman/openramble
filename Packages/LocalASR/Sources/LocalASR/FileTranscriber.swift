import DictationCore
import Foundation

public struct FileTranscript: Sendable {
    public let text: String
    public let words: [ASRResult.Word]
    public let duration: Double
    public let recognitionSeconds: Double
    let decodingSeconds: Double
    let dispatchSeconds: Double

    init(text: String, words: [ASRResult.Word], duration: Double, recognitionSeconds: Double,
         decodingSeconds: Double = 0, dispatchSeconds: Double = 0) {
        self.text = text
        self.words = words
        self.duration = duration
        self.recognitionSeconds = recognitionSeconds
        self.decodingSeconds = decodingSeconds
        self.dispatchSeconds = dispatchSeconds
    }
}

/// One model, one inference at a time, and one fragment prepared ahead.
/// Long files never become one PCM array. Failed inputs do not stop other files.
public struct FileTranscriber: Sendable {
    private let transcriber: LocalTranscriber
    private let priority: DictationPriority?
    private let segmentSeconds: Int

    public init(transcriber: LocalTranscriber, priority: DictationPriority? = nil,
                segmentSeconds: Int = 30) {
        precondition((15...60).contains(segmentSeconds))
        self.transcriber = transcriber
        self.priority = priority
        self.segmentSeconds = segmentSeconds
    }

    public func transcribe(
        files: [URL],
        progress: @escaping @Sendable (_ file: Int, _ seconds: Double, _ total: Double) -> Void = { _, _, _ in },
        completed: @escaping @Sendable (Int, Result<FileTranscript, Error>) async -> Void
    ) async throws {
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            do {
                let result = try await transcribe(file: file) { seconds, total in
                    progress(index, seconds, total)
                }
                try Task.checkCancellation()
                await completed(index, .success(result))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                await completed(index, .failure(error))
            }
        }
    }

    private func transcribe(
        file: URL, progress: @Sendable (Double, Double) -> Void
    ) async throws -> FileTranscript {
        try await transcriber.withPreparedModel { generation in
            let chunks = try await FileAudioChunks(url: file, seconds: segmentSeconds)
            return try await transcribe(chunks: chunks, generation: generation, progress: progress)
        }
    }

    func transcribe(chunks: FileAudioChunks, generation: Int,
                    progress: @Sendable (Double, Double) -> Void = { _, _ in }) async throws -> FileTranscript {
        var joiner = TimedTranscriptJoiner()
        var recognitionSeconds = 0.0
        var dispatchSeconds = 0.0
        var next = try await chunks.next()
        while let chunk = next {
            try Task.checkCancellation()
            // The CPU prepares only the next fragment while the GPU runs.
            async let following = chunks.next()
            let result = try await decode(chunk.samples, generation: generation)
            try joiner.append(result, chunk: chunk, duration: chunks.duration)
            recognitionSeconds += result.processingDuration
            dispatchSeconds += result.engineDispatchDuration
            progress(min(chunks.duration, Double(chunk.endFrame) / 16_000), chunks.duration)
            next = try await following
        }
        return FileTranscript(text: joiner.words.map(\.text).joined(separator: " "),
                              words: joiner.words, duration: chunks.duration,
                              recognitionSeconds: recognitionSeconds,
                              decodingSeconds: await chunks.readSeconds,
                              dispatchSeconds: dispatchSeconds)
    }

    private func decode(_ samples: [Float], generation: Int) async throws -> ASRResult {
        while true {
            try await priority?.waitForTurn()
            try Task.checkCancellation()
            let results = try await transcriber.transcribeChunk(samples, generation: generation,
                shouldYield: { (try? priority?.isActive()) ?? false })
            guard results.count == 1, let result = results.first else {
                throw ASREngineError.inferenceFailed("the engine returned an incomplete result")
            }
            switch result {
            case let .success(value): return value
            case .failure(.cancelled): continue // Dictation yielded this fragment; keep its completed prefix.
            case let .failure(error): throw error
            }
        }
    }
}
