import AVFoundation
import CoreML
import CryptoKit
import Foundation
import FluidAudio

private actor UpdateStore {
    private var values: [SlidingWindowTranscriptionUpdate] = []

    func append(_ value: SlidingWindowTranscriptionUpdate) {
        values.append(value)
    }

    func snapshot() -> [SlidingWindowTranscriptionUpdate] {
        values
    }
}

private struct TimingRecord: Codable {
    let token: String
    let tokenId: Int
    let startTime: Double
    let endTime: Double
    let confidence: Float

    init(_ timing: TokenTiming) {
        token = timing.token
        tokenId = timing.tokenId
        startTime = timing.startTime
        endTime = timing.endTime
        confidence = timing.confidence
    }
}

private struct Report: Codable {
    let appHead: String
    let fluidAudioRevision: String
    let modelDirectory: String
    let fixture: String
    let sampleCount: Int
    let durationSeconds: Double
    let offlineText: String
    let previewText: String
    let textExact: Bool
    let offlineTextSHA256: String
    let previewTextSHA256: String
    let offlineTimingSHA256: String
    let previewUpdateTimingSHA256: String
    let offlineTokenTimings: [TimingRecord]
    let previewUpdateTokenTimings: [TimingRecord]
    let previewUpdateCount: Int
    let previewConfirmed: String
    let previewVolatile: String
    let offlineWallMilliseconds: Double
    let previewWallMilliseconds: Double
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func hash<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256(try encoder.encode(value))
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1e15
}

private func pcmBuffer(_ samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ), let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
    ) else {
        throw NSError(domain: "preview-parity", code: 10)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    guard let destination = buffer.floatChannelData?[0] else {
        throw NSError(domain: "preview-parity", code: 11)
    }
    samples.withContiguousStorageIfAvailable { storage in
        destination.update(from: storage.baseAddress!, count: storage.count)
    }
    return buffer
}

@main
private enum PreviewParity {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 else {
            throw NSError(
                domain: "preview-parity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "usage: preview-parity MODEL_DIR FIXTURE_WAV"]
            )
        }

        let modelDirectory = URL(fileURLWithPath: args[0], isDirectory: true)
        let fixture = args[1]
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(path: fixture)

        ModelHub.offlineMode = true
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let models = try await AsrModels.load(
            from: modelDirectory,
            configuration: configuration,
            version: .v3,
            encoderPrecision: .int8,
            encoderComputeUnits: .all
        )

        let offline = AsrManager(
            config: ASRConfig(
                tdtConfig: TdtConfig(maxTokensPerChunk: 600),
                parallelChunkConcurrency: 4,
                melChunkContext: false,
                dualDecodeArbitration: false
            )
        )
        try await offline.loadModels(models)
        var offlineState = TdtDecoderState.make(decoderLayers: await offline.decoderLayerCount)
        let offlineStarted = ContinuousClock.now
        let offlineResult = try await offline.transcribe(
            samples,
            decoderState: &offlineState,
            language: nil
        )
        let offlineWall = offlineStarted.duration(to: .now)

        let preview = SlidingWindowAsrManager(
            config: SlidingWindowAsrConfig(
                chunkSeconds: 1.0,
                hypothesisChunkSeconds: 0.5,
                leftContextSeconds: 0.5,
                rightContextSeconds: 0.25,
                minContextForConfirmation: 3.0,
                confirmationThreshold: 0.8
            )
        )
        try await preview.loadModels(models)
        try await preview.startStreaming(source: .microphone)

        let store = UpdateStore()
        let updates = await preview.transcriptionUpdates
        let updateTask = Task {
            for await update in updates {
                await store.append(update)
                if Task.isCancelled { break }
            }
        }

        let previewStarted = ContinuousClock.now
        let blockSize = 1_600
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + blockSize)
            await preview.streamAudio(try pcmBuffer(samples[offset..<end]))
            offset = end
        }
        let previewText = try await preview.finish()
        let previewWall = previewStarted.duration(to: .now)
        updateTask.cancel()
        let capturedUpdates = await store.snapshot()
        await preview.cancel()

        let offlineTimings = (offlineResult.tokenTimings ?? []).map(TimingRecord.init)
        let previewTimings = capturedUpdates.flatMap(\.tokenTimings).map(TimingRecord.init)
        let report = Report(
            appHead: "f2b6e8cc66d20f7a07094f79af0faf3ba861af64",
            fluidAudioRevision: "ee9a7f12d91710da53de6d75f8b7160e09eccee4",
            modelDirectory: modelDirectory.path,
            fixture: fixture,
            sampleCount: samples.count,
            durationSeconds: Double(samples.count) / 16_000,
            offlineText: offlineResult.text,
            previewText: previewText,
            textExact: offlineResult.text == previewText,
            offlineTextSHA256: sha256(Data(offlineResult.text.utf8)),
            previewTextSHA256: sha256(Data(previewText.utf8)),
            offlineTimingSHA256: try hash(offlineTimings),
            previewUpdateTimingSHA256: try hash(previewTimings),
            offlineTokenTimings: offlineTimings,
            previewUpdateTokenTimings: previewTimings,
            previewUpdateCount: capturedUpdates.count,
            previewConfirmed: await preview.confirmedTranscript,
            previewVolatile: await preview.volatileTranscript,
            offlineWallMilliseconds: milliseconds(offlineWall),
            previewWallMilliseconds: milliseconds(previewWall)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !report.textExact {
            exit(42)
        }
    }
}
