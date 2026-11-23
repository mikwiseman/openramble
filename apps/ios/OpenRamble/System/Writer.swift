import DictationCore
import Foundation
import LocalASR

/// Turns a recording into the words a person reads.
///
/// The recognizer is the same `LocalTranscriber` the Mac uses, which on the
/// iPhone runs our own engine (`OreAdapter`), and the words then pass through
/// the same `TextPipeline` the Mac applies before it types: hesitations and
/// stutters removed, spoken corrections honoured, punctuation and capitals
/// settled, a long pause after a sentence made a paragraph. Recordings longer
/// than 30 seconds are cut at pauses by the planner the Mac and the server
/// share.
actor Writer {
    struct Words: Sendable, Equatable {
        /// What the person reads.
        let text: String
        /// Seconds of audio, as the recognizer counted them.
        let audioDuration: TimeInterval
        /// Seconds the recognizer spent.
        let recognitionDuration: TimeInterval
    }

    enum Failure: Error, Equatable {
        case notReady
    }

    private let transcriber: LocalTranscriber
    private(set) var isReady = false

    init(transcriber: LocalTranscriber = LocalTranscriber()) {
        self.transcriber = transcriber
    }

    /// Opens the model. The engine maps the file rather than copying it, so
    /// this takes milliseconds once the file is in the system's cache.
    func prepare(modelDirectory: URL) async throws {
        try await transcriber.prepare(modelDirectory: modelDirectory)
        isReady = true
    }

    /// Runs one second of silence through the engine so its pages are in
    /// memory before the person stops speaking. Called when a take starts.
    func warmUp() async {
        guard isReady else { return }
        try? await transcriber.warmUpInference()
    }

    func unload() async {
        isReady = false
        await transcriber.unload()
    }

    func write(fileURL: URL) async throws -> Words {
        guard isReady else { throw Failure.notReady }
        let heard = try await transcriber.transcribe(fileURL: fileURL)
        return Words(
            text: Self.polish(heard),
            audioDuration: heard.audioDuration,
            recognitionDuration: heard.processingDuration
        )
    }

    /// The Mac's own post-processing, in prose mode: the words are going into
    /// notes and messages, where a paragraph is welcome. "New line" said at the
    /// end becomes one; "send it" stays words, because there is nothing here to
    /// press Return in.
    static func polish(_ heard: ASRResult) -> String {
        TextPipeline(mode: .prose)
            .run(ParagraphBreaks.mark(heard.text, words: heard.words))
            .output.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
