import AVFoundation
import CryptoKit
import Foundation
import Speech

private struct Event: Codable {
    let deliveredNS: Int64
    let isFinal: Bool
    let text: String
    let rangeStartSeconds: Double
    let rangeDurationSeconds: Double
    let finalizationSeconds: Double
}

private struct Trial: Codable {
    let model: String
    let fixtureSHA256: String
    let locale: String
    let sampleCount: Int
    let durationSeconds: Double
    let paced: Bool
    let assetStatus: String
    let prepareNS: Int64
    let startNS: Int64
    let feedWallNS: Int64
    let stopToFinalizeNS: Int64
    let totalWallNS: Int64
    let finalText: String
    let events: [Event]
}

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case invalidPCM
    case localeUnsupported
    case assetNotInstalled(String)
    case formatUnavailable
    case unexpectedFormat(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: speech-analyzer-probe <dictation|speech> <f32le> <locale> <paced:0|1> <repeats>"
        case .invalidPCM:
            return "input must be nonempty native-endian Float32 PCM"
        case .localeUnsupported:
            return "locale unsupported by DictationTranscriber"
        case let .assetNotInstalled(status):
            return "asset is not installed (status=\(status)); this probe never downloads"
        case .formatUnavailable:
            return "SpeechAnalyzer returned no compatible format"
        case let .unexpectedFormat(description):
            return "unexpected analyzer format: \(description)"
        }
    }
}

@available(macOS 26.0, *)
private enum TranscriberChoice {
    case dictation(DictationTranscriber)
    case speech(SpeechTranscriber)

    var name: String {
        switch self {
        case .dictation: "dictation"
        case .speech: "speech"
        }
    }

    var module: any SpeechModule {
        switch self {
        case let .dictation(value): value
        case let .speech(value): value
        }
    }

    func resultTask(
        origin: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> Task<[Event], Error> {
        switch self {
        case let .dictation(transcriber):
            return Task {
                var events: [Event] = []
                for try await result in transcriber.results {
                    events.append(Event(result, deliveredNS: nanoseconds(origin.duration(to: clock.now))))
                }
                return events
            }
        case let .speech(transcriber):
            return Task {
                var events: [Event] = []
                for try await result in transcriber.results {
                    events.append(Event(result, deliveredNS: nanoseconds(origin.duration(to: clock.now))))
                }
                return events
            }
        }
    }
}

@available(macOS 26.0, *)
private extension Event {
    init(_ result: DictationTranscriber.Result, deliveredNS: Int64) {
        self.init(
            deliveredNS: deliveredNS,
            isFinal: result.isFinal,
            text: String(result.text.characters),
            rangeStartSeconds: CMTimeGetSeconds(result.range.start),
            rangeDurationSeconds: CMTimeGetSeconds(result.range.duration),
            finalizationSeconds: CMTimeGetSeconds(result.resultsFinalizationTime)
        )
    }

    init(_ result: SpeechTranscriber.Result, deliveredNS: Int64) {
        self.init(
            deliveredNS: deliveredNS,
            isFinal: result.isFinal,
            text: String(result.text.characters),
            rangeStartSeconds: CMTimeGetSeconds(result.range.start),
            rangeDurationSeconds: CMTimeGetSeconds(result.range.duration),
            finalizationSeconds: CMTimeGetSeconds(result.resultsFinalizationTime)
        )
    }
}

private func nanoseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    precondition(!seconds.overflow)
    let attoseconds = components.attoseconds / 1_000_000_000
    return seconds.partialValue + attoseconds
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func loadSamples(_ url: URL) throws -> ([Float], String) {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else {
        throw ProbeError.invalidPCM
    }
    let samples = data.withUnsafeBytes { raw -> [Float] in
        Array(raw.bindMemory(to: Float.self))
    }
    guard samples.allSatisfy(\.isFinite) else { throw ProbeError.invalidPCM }
    return (samples, sha256(data))
}

private func makeBuffers(samples: [Float], format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
    let framesPerBuffer = 320 // 20 ms at 16 kHz
    var result: [AVAudioPCMBuffer] = []
    result.reserveCapacity((samples.count + framesPerBuffer - 1) / framesPerBuffer)
    var offset = 0
    while offset < samples.count {
        let count = min(framesPerBuffer, samples.count - offset)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(count)
        ), let channel = buffer.int16ChannelData?[0] else {
            throw ProbeError.unexpectedFormat(String(describing: format))
        }
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            let value = max(-1, min(1, samples[offset + index]))
            channel[index] = Int16(clamping: Int((value * 32_767).rounded()))
        }
        result.append(buffer)
        offset += count
    }
    return result
}

@available(macOS 26.0, *)
private func runTrial(
    samples: [Float],
    fixtureSHA256: String,
    localeIdentifier: String,
    model: String,
    paced: Bool
) async throws -> Trial {
    let requestedLocale = Locale(identifier: localeIdentifier)
    let locale: Locale
    let choice: TranscriberChoice
    switch model {
    case "dictation":
        guard let supported = await DictationTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else { throw ProbeError.localeUnsupported }
        locale = supported
        choice = .dictation(
            DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        )
    case "speech":
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(
                  equivalentTo: requestedLocale
              )
        else { throw ProbeError.localeUnsupported }
        locale = supported
        choice = .speech(
            SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        )
    default:
        throw ProbeError.usage
    }
    _ = try await AssetInventory.reserve(locale: locale)
    var assetStatus = await AssetInventory.status(forModules: [choice.module])
    let assetDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while assetStatus != .installed, ContinuousClock.now < assetDeadline {
        try await Task.sleep(for: .milliseconds(100))
        assetStatus = await AssetInventory.status(forModules: [choice.module])
    }
    guard assetStatus == .installed else {
        throw ProbeError.assetNotInstalled(String(describing: assetStatus))
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [choice.module]
    ) else {
        throw ProbeError.formatUnavailable
    }
    guard format.sampleRate == 16_000,
          format.channelCount == 1,
          format.commonFormat == .pcmFormatInt16
    else {
        throw ProbeError.unexpectedFormat(String(describing: format))
    }
    let buffers = try makeBuffers(samples: samples, format: format)
    let analyzer = SpeechAnalyzer(modules: [choice.module])
    let clock = ContinuousClock()
    let trialStarted = clock.now
    let prepareStarted = clock.now
    try await analyzer.prepareToAnalyze(in: format)
    let prepareNS = nanoseconds(prepareStarted.duration(to: clock.now))

    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let deliveryOrigin = clock.now
    let resultTask = choice.resultTask(origin: deliveryOrigin, clock: clock)

    let startStarted = clock.now
    try await analyzer.start(inputSequence: stream)
    let startNS = nanoseconds(startStarted.duration(to: clock.now))
    let feedStarted = clock.now
    var sampleOffset = 0
    for buffer in buffers {
        continuation.yield(
            AnalyzerInput(
                buffer: buffer,
                bufferStartTime: CMTime(value: Int64(sampleOffset), timescale: 16_000)
            )
        )
        sampleOffset += Int(buffer.frameLength)
        if paced {
            let deadline = feedStarted.advanced(
                by: .nanoseconds(Int64(sampleOffset) * 1_000_000_000 / 16_000)
            )
            try await clock.sleep(until: deadline)
        }
    }
    let stopStarted = clock.now
    continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let events = try await resultTask.value
    let finished = clock.now
    let finalText = events.filter(\.isFinal).map(\.text).joined(separator: " ")
    return Trial(
        model: choice.name,
        fixtureSHA256: fixtureSHA256,
        locale: locale.identifier,
        sampleCount: samples.count,
        durationSeconds: Double(samples.count) / 16_000,
        paced: paced,
        assetStatus: String(describing: assetStatus),
        prepareNS: prepareNS,
        startNS: startNS,
        feedWallNS: nanoseconds(feedStarted.duration(to: stopStarted)),
        stopToFinalizeNS: nanoseconds(stopStarted.duration(to: finished)),
        totalWallNS: nanoseconds(trialStarted.duration(to: finished)),
        finalText: finalText,
        events: events
    )
}

@main
private struct Main {
    static func main() async {
        do {
            guard #available(macOS 26.0, *), CommandLine.arguments.count == 6,
                  let pacedValue = Int(CommandLine.arguments[4]),
                  let repeats = Int(CommandLine.arguments[5]),
                  (pacedValue == 0 || pacedValue == 1), repeats > 0
            else {
                throw ProbeError.usage
            }
            let (samples, digest) = try loadSamples(
                URL(fileURLWithPath: CommandLine.arguments[2])
            )
            var trials: [Trial] = []
            for _ in 0..<repeats {
                trials.append(
                    try await runTrial(
                        samples: samples,
                        fixtureSHA256: digest,
                        localeIdentifier: CommandLine.arguments[3],
                        model: CommandLine.arguments[1],
                        paced: pacedValue == 1
                    )
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(trials))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
