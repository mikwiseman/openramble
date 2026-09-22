import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum ScreenRecordingError: LocalizedError, Sendable {
    case noDisplay
    case notPrepared
    case alreadyRecording
    case notRecording
    case permissionDenied(String)
    case cameraUnavailable
    case writerUnavailable
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Не найден экран для записи"
        case .notPrepared: return "Запись экрана ещё не подготовлена"
        case .alreadyRecording: return "Запись уже идёт"
        case .notRecording: return "Запись не запущена"
        case let .permissionDenied(name): return "Нет доступа: \(name)"
        case .cameraUnavailable: return "Камера недоступна"
        case .writerUnavailable: return "Не удалось подготовить файл записи"
        case let .writerFailed(message): return message
        }
    }
}

/// A small AVAssetWriter boundary. All calls happen on ScreenMediaState's
/// serial media queue, except `finish`, which is called after that queue is
/// drained. Audio is deliberately one AAC track: the aligned microphone and
/// system channels are mixed before encoding.
final class ScreenMovieWriter: @unchecked Sendable {
    let outputURL: URL
    let width: Int
    let height: Int

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription
    private var started = false
    private var finished = false
    private var lastVideoTime = CMTime.invalid
    private var error: Error?

    init(url: URL, width: Int, height: Int) throws {
        outputURL = url
        self.width = width
        self.height = height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        if #available(macOS 14.0, *) {
            writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(max(width * height * 4, 4_000_000), 24_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw ScreenRecordingError.writerUnavailable }
        writer.add(video)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000,
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(audio) else { throw ScreenRecordingError.writerUnavailable }
        writer.add(audio)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        guard let description = Self.makeAudioFormatDescription() else {
            throw ScreenRecordingError.writerUnavailable
        }
        self.writer = writer
        videoInput = video
        audioInput = audio
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                                                        sourcePixelBufferAttributes: attributes)
        audioFormat = description
    }

    var writerError: Error? { error ?? writer.error }

    @discardableResult
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> Bool {
        guard !finished else { return false }
        guard presentationTime.isValid else { return false }
        let time: CMTime
        if lastVideoTime.isValid, presentationTime <= lastVideoTime {
            time = lastVideoTime + CMTime(value: 1, timescale: 30)
        } else {
            time = presentationTime
        }
        if !startIfNeeded(at: time) { return false }
        guard videoInput.isReadyForMoreMediaData else { return false }
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            error = writer.error ?? ScreenRecordingError.writerFailed("Не удалось записать кадр экрана")
            return false
        }
        lastVideoTime = time
        return true
    }

    @discardableResult
    func appendAudio(microphone: [Float], system: [Float], startFrame: Int) -> Bool {
        guard !finished else { return false }
        let count = max(microphone.count, system.count)
        guard count > 0 else { return true }
        var stereo = [Float](repeating: 0, count: count * 2)
        for index in 0..<count {
            let mic = index < microphone.count ? microphone[index] : 0
            let other = index < system.count ? system[index] : 0
            let mixed = max(-1, min(1, mic + other))
            stereo[index * 2] = mixed
            stereo[index * 2 + 1] = mixed
        }
        guard let sample = Self.makeSampleBuffer(stereo: stereo,
                                                 frameCount: count,
                                                 startFrame: startFrame,
                                                 format: audioFormat) else { return false }
        let timestamp = CMTime(value: CMTimeValue(max(0, startFrame)), timescale: 16_000)
        if !startIfNeeded(at: timestamp) { return false }
        guard audioInput.isReadyForMoreMediaData else { return false }
        guard audioInput.append(sample) else {
            error = writer.error ?? ScreenRecordingError.writerFailed("Не удалось записать звук")
            return false
        }
        return true
    }

    func finish() async throws {
        guard !finished else {
            if let error = writerError { throw error }
            return
        }
        finished = true
        guard started else {
            writer.cancelWriting()
            throw writerError ?? ScreenRecordingError.writerFailed("Запись не содержит кадров")
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting { [weak self] in
                guard let self else { continuation.resume(); return }
                if self.writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: self.writerError ?? ScreenRecordingError.writerFailed("Не удалось закрыть видео"))
                }
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        writer.cancelWriting()
    }

    private func startIfNeeded(at time: CMTime) -> Bool {
        if started { return writer.status == .writing }
        guard writer.startWriting() else {
            error = writer.error ?? ScreenRecordingError.writerFailed("Не удалось начать запись")
            return false
        }
        // Both tracks use the recording timeline (the first audio block is
        // allowed to arrive after the first display frame because the meeting
        // aligner deliberately holds a jitter window). Starting at zero keeps
        // that normal ordering valid; starting at the first video PTS would
        // make a perfectly valid audio block at frame zero look like a
        // backwards timestamp and silently discard it.
        writer.startSession(atSourceTime: .zero)
        started = true
        return true
    }

    private static func makeAudioFormatDescription() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var result: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                              asbd: &asbd,
                                              layoutSize: 0,
                                              layout: nil,
                                              magicCookieSize: 0,
                                              magicCookie: nil,
                                              extensions: nil,
                                              formatDescriptionOut: &result) == noErr else { return nil }
        return result
    }

    private static func makeSampleBuffer(stereo: [Float], frameCount: Int,
                                         startFrame: Int,
                                         format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let samples = stereo.prefix(frameCount * 2).map { value in
            Int16(max(-1, min(1, value)) * 32_767)
        }
        let byteCount = samples.count * MemoryLayout<Int16>.stride
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: byteCount,
                                                 flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let writeStatus = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!,
                                           blockBuffer: block,
                                           offsetIntoDestination: 0,
                                           dataLength: byteCount)
        }
        guard writeStatus == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(max(0, startFrame)), timescale: 16_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: block,
                                        formatDescription: format,
                                        sampleCount: frameCount,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: [byteCount],
                                        sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
