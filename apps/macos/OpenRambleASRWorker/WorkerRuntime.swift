import ASRWorkerProtocol
import Darwin
import DictationCore
import Foundation
import LocalASR
import os

private let workerLog = Logger(subsystem: "is.waiwai.dictation", category: "asr-worker")

actor ASRWorkerRuntime {
    private let transcriber = LocalTranscriber()
    private var didHandshake = false

    /// Returns false only for an orderly shutdown request.
    func handle(_ frame: ASRWireFrame) async -> Bool {
        if frame.kind == .shutdown { return false }

        do {
            guard didHandshake || frame.kind == .hello else {
                throw ASRWorkerFailure(
                    code: .protocolMismatch,
                    message: "The ASR worker handshake has not completed."
                )
            }

            switch frame.kind {
            case .hello:
                try handleHello(frame)
            case .prepareMain:
                try await prepareMain(frame)
            case .prepareVocabulary:
                try await prepareVocabulary(frame)
            case .warmInference:
                try await warmInference(frame)
            case .transcribeSamples:
                try await transcribeSamples(frame)
            case .transcribeFile:
                try await transcribeFile(frame)
            case .unloadModels:
                try await unloadModels(frame)
            case .helloAcknowledged, .acknowledged, .result, .failure, .shutdown:
                throw ASRWorkerFailure(code: .invalidRequest, message: "Unexpected worker message kind.")
            }
        } catch let failure as ASRWorkerFailure {
            sendFailure(failure, requestID: frame.requestID)
        } catch let failure as VocabularyBoostError {
            let message: String
            let termIndex: Int
            switch failure {
            case let .termNotTokenizable(index):
                message = "Vocabulary term \(index) cannot be tokenized."
                termIndex = index
            }
            sendFailure(
                ASRWorkerFailure(
                    code: .vocabularyInvalid,
                    message: message,
                    termIndex: termIndex
                ),
                requestID: frame.requestID
            )
        } catch let failure as ASREngineError {
            sendFailure(Self.wireFailure(failure), requestID: frame.requestID)
        } catch is CancellationError {
            sendFailure(
                ASRWorkerFailure(code: .cancelled, message: "Recognition was cancelled."),
                requestID: frame.requestID
            )
        } catch {
            workerLog.error("worker request failed code=internal")
            sendFailure(
                ASRWorkerFailure(code: .internalFailure, message: "The local recognizer failed."),
                requestID: frame.requestID
            )
        }
        return true
    }

    private func handleHello(_ frame: ASRWireFrame) throws {
        guard !didHandshake, frame.payload.isEmpty else {
            throw ASRWorkerFailure(code: .invalidRequest, message: "Invalid ASR worker handshake.")
        }
        let hello = try ASRWorkerJSON.decode(ASRWorkerHello.self, from: frame.metadata)
        guard hello.protocolVersion == ASRWorkerProtocol.version,
              hello.parentProcessIdentifier == getppid()
        else {
            throw ASRWorkerFailure(
                code: .protocolMismatch,
                message: "The app and ASR worker protocol versions do not match."
            )
        }
        didHandshake = true
        try send(
            kind: .helloAcknowledged,
            requestID: frame.requestID,
            value: ASRWorkerHelloAcknowledgement(
                protocolVersion: ASRWorkerProtocol.version,
                workerProcessIdentifier: getpid()
            )
        )
    }

    private func prepareMain(_ frame: ASRWireFrame) async throws {
        guard frame.payload.isEmpty else {
            throw ASRWorkerFailure(code: .invalidRequest, message: "Model preparation has no binary payload.")
        }
        let request = try ASRWorkerJSON.decode(ASRWorkerPrepareMain.self, from: frame.metadata)
        let started = ContinuousClock.now
        try await transcriber.prepare(
            modelDirectory: URL(fileURLWithPath: request.modelDirectory, isDirectory: true)
        )
        workerLog.info(
            "main model ready seconds=\(started.duration(to: .now).workerSeconds, format: .fixed(precision: 3))"
        )
        try send(kind: .acknowledged, requestID: frame.requestID, value: ASRWorkerAcknowledgement())
    }

    private func unloadModels(_ frame: ASRWireFrame) async throws {
        guard frame.payload.isEmpty, frame.metadata.isEmpty else {
            throw ASRWorkerFailure(code: .invalidRequest, message: "Model unload carries no payload.")
        }
        let started = ContinuousClock.now
        await transcriber.unload()
        workerLog.info(
            "models unloaded, worker resident seconds=\(started.duration(to: .now).workerSeconds, format: .fixed(precision: 3))"
        )
        try send(kind: .acknowledged, requestID: frame.requestID, value: ASRWorkerAcknowledgement())
    }

    private func prepareVocabulary(_ frame: ASRWireFrame) async throws {
        guard frame.payload.isEmpty else {
            throw ASRWorkerFailure(code: .invalidRequest, message: "Vocabulary preparation has no binary payload.")
        }
        let request = try ASRWorkerJSON.decode(ASRWorkerVocabulary.self, from: frame.metadata)
        let boost = VocabularyBoost(
            terms: request.terms.map { VocabularyBoost.Term(text: $0.text, aliases: $0.aliases) },
            minSimilarity: request.minimumSimilarity,
            biasWeight: request.biasWeight
        )
        let started = ContinuousClock.now
        try await transcriber.prepareVocabulary(
            modelDirectory: URL(fileURLWithPath: request.modelDirectory, isDirectory: true),
            boost: boost
        )
        workerLog.info(
            "vocabulary ready revision=\(request.revision) terms=\(request.terms.count) seconds=\(started.duration(to: .now).workerSeconds, format: .fixed(precision: 3))"
        )
        try send(
            kind: .acknowledged,
            requestID: frame.requestID,
            value: ASRWorkerAcknowledgement(vocabularyRevision: request.revision)
        )
    }

    private func warmInference(_ frame: ASRWireFrame) async throws {
        guard frame.payload.isEmpty else {
            throw ASRWorkerFailure(code: .invalidRequest, message: "Inference warm-up has no binary payload.")
        }
        let started = ContinuousClock.now
        try await transcriber.warmUpInference()
        workerLog.info(
            "inference ready seconds=\(started.duration(to: .now).workerSeconds, format: .fixed(precision: 3))"
        )
        try send(kind: .acknowledged, requestID: frame.requestID, value: ASRWorkerAcknowledgement())
    }

    private func transcribeSamples(_ frame: ASRWireFrame) async throws {
        let request = try ASRWorkerJSON.decode(ASRWorkerTranscribeSamples.self, from: frame.metadata)
        guard request.sampleRate == ASRWorkerProtocol.sampleRate,
              request.sampleCount > 0,
              request.sampleCount <= ASRWorkerProtocol.maximumSamples,
              request.sampleCount <= Int.max / MemoryLayout<Float>.size,
              frame.payload.count == request.sampleCount * MemoryLayout<Float>.size
        else {
            throw ASRWorkerFailure(code: .invalidAudio, message: "Expected bounded 16 kHz mono Float32 audio.")
        }

        var samples = [Float](repeating: 0, count: request.sampleCount)
        _ = samples.withUnsafeMutableBytes { destination in
            frame.payload.copyBytes(to: destination)
        }
        let result = try await transcriber.transcribe(
            samples: samples,
            languageHint: request.languageHint
        )
        try sendResult(result, requestID: frame.requestID)
    }

    private func transcribeFile(_ frame: ASRWireFrame) async throws {
        guard frame.payload.isEmpty else {
            throw ASRWorkerFailure(code: .invalidRequest, message: "File transcription has no binary payload.")
        }
        let request = try ASRWorkerJSON.decode(ASRWorkerTranscribeFile.self, from: frame.metadata)
        guard request.path.hasPrefix("/") else {
            throw ASRWorkerFailure(code: .invalidAudio, message: "The recording path must be absolute.")
        }
        let result = try await transcriber.transcribe(
            fileURL: URL(fileURLWithPath: request.path),
            languageHint: request.languageHint
        )
        try sendResult(result, requestID: frame.requestID)
    }

    private func sendResult(_ result: ASRResult, requestID: UInt64) throws {
        guard result.text.utf8.count <= ASRWorkerProtocol.maximumTranscriptUTF8Bytes,
              result.words.count <= ASRWorkerProtocol.maximumResultWords,
              result.audioDuration.isFinite,
              result.audioDuration >= 0,
              result.processingDuration.isFinite,
              result.processingDuration >= 0,
              result.words.allSatisfy({
                  $0.text.utf8.count <= ASRWorkerProtocol.maximumWordUTF8Bytes &&
                      $0.start.isFinite && $0.end.isFinite &&
                      $0.start >= 0 && $0.end >= $0.start &&
                      ($0.confidence.map {
                          $0.isFinite && $0 >= 0 && $0 <= 1
                      } ?? true)
              })
        else {
            throw ASRWorkerFailure(
                code: .internalFailure,
                message: "The recognition result exceeds the private protocol limit."
            )
        }
        try send(
            kind: .result,
            requestID: requestID,
            value: ASRWorkerResult(
                text: result.text,
                words: result.words.map {
                    ASRWorkerResult.Word(
                        text: $0.text,
                        start: $0.start,
                        end: $0.end,
                        confidence: $0.confidence
                    )
                },
                audioDuration: result.audioDuration,
                processingDuration: result.processingDuration
            )
        )
    }

    private func send<Value: Encodable>(kind: ASRWireKind, requestID: UInt64, value: Value) throws {
        let metadata = try ASRWorkerJSON.encode(value)
        guard metadata.count <= ASRWorkerProtocol.maximumMetadataBytes else {
            throw ASRWorkerFailure(code: .internalFailure, message: "The recognition result is too large.")
        }
        try ASRWireIO.write(
            ASRWireFrame(kind: kind, requestID: requestID, metadata: metadata),
            to: STDOUT_FILENO
        )
    }

    private func sendFailure(_ failure: ASRWorkerFailure, requestID: UInt64) {
        workerLog.error("worker response failure code=\(failure.code.rawValue, privacy: .public)")
        try? send(kind: .failure, requestID: requestID, value: failure)
    }

    private static func wireFailure(_ failure: ASREngineError) -> ASRWorkerFailure {
        switch failure {
        case .modelsNotLoaded:
            ASRWorkerFailure(code: .modelsNotLoaded, message: "The local model is not loaded.")
        case .modelsUnavailable:
            ASRWorkerFailure(code: .modelsUnavailable, message: "The local model is unavailable.")
        case .unsupportedAudioFormat:
            ASRWorkerFailure(code: .invalidAudio, message: "The recording format is not supported.")
        case .inferenceFailed:
            ASRWorkerFailure(code: .inferenceFailed, message: "Local recognition failed.")
        case .cancelled:
            ASRWorkerFailure(code: .cancelled, message: "Recognition was cancelled.")
        }
    }
}

private extension Duration {
    var workerSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
