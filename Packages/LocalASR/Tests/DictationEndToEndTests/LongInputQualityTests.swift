import AVFoundation
import Darwin
import DictationCore
import LocalASR
import XCTest

/// Opt-in, content-controlled speech rather than padded duration. References
/// are fixed before recognition; the eight-minute case has a noise floor that
/// prevents the live segmenter's quiet-pause rule from hiding the long tail.
@MainActor
final class LongInputQualityTests: XCTestCase {
    func testDenseRussianAndEnglishAtFourFiveEightAndFifteenMinutes() async throws {
        guard ProcessInfo.processInfo.environment["OPENRAMBLE_LONG_DICTATION_GATE"] == "1" else {
            throw XCTSkip("set OPENRAMBLE_LONG_DICTATION_GATE=1 for the long speech matrix")
        }
        let transcriber = try await requireEndToEndTranscriber()
        for voice in [SpeechVoice.russian, .english] {
            let paragraphs = voice == .russian ? Self.russian : Self.english
            var clips: [[Float]] = []
            for paragraph in paragraphs {
                let url = try await SpeechFixtures.shared.speech(paragraph, voice: voice)
                clips.append(try await AudioFileReader().samplesOnDiskQueue(from: url))
            }
            let ending = voice == .russian ? "Последнее слово телескоп." : "The final word is telescope."
            let endingURL = try await SpeechFixtures.shared.speech(ending, voice: voice)
            let endingPCM = try await AudioFileReader().samplesOnDiskQueue(from: endingURL)
            for seconds in [240, 300, 480, 900] {
                var samples: [Float] = [], reference: [String] = []
                var index = 0
                while samples.count < seconds * 16_000 {
                    samples += clips[index % clips.count]
                    reference.append(paragraphs[index % paragraphs.count])
                    index += 1
                }
                samples += endingPCM
                reference.append(ending)
                if seconds == 480 {
                    var seed: UInt64 = 7
                    for i in samples.indices {
                        seed = seed &* 6364136223846793005 &+ 1
                        samples[i] += (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * 0.025
                    }
                }
                let url = try write(samples)
                defer { try? FileManager.default.removeItem(at: url) }
                let started = ContinuousClock.now
                let result = try await transcriber.transcribe(fileURL: url)
                let elapsed = started.duration(to: .now)
                let expected = Self.words(reference.joined(separator: " "))
                let errors = Self.distance(expected, Self.words(result.text))
                let rate = Double(errors) / Double(expected.count)
                XCTAssertLessThanOrEqual(rate, 0.08, "fixed-reference WER, not self-comparison")
                let marker = voice == .russian ? "телескоп" : "telescope"
                XCTAssertEqual(Self.words(result.text).filter { $0 == marker }.count, 1)
                XCTAssertTrue(Self.words(result.text).suffix(8).contains(marker))
                XCTAssertEqual(result.audioDuration, Double(samples.count) / 16_000, accuracy: 0.001)
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                print("[long-quality] voice=\(voice.rawValue) audio=\(result.audioDuration)s noise=\(seconds == 480) elapsed=\(elapsed) engine=\(result.processingDuration)s WER=\(rate) processPeakRSS=\(usage.ru_maxrss)")
            }
        }
    }

    // No private or downloaded recordings. Varied sentences exercise names,
    // repetitions, mixed language, and boundaries throughout dense speech.
    private static let russian = [
        "Алексей Петров проверил документы и отправил Марии Ивановой подробный ответ. Мы обсудили новую версию приложения, затем проверили работу микрофона. Важно сохранить начало, середину и конец записи.",
        "Сегодня команда готовит обновление. Сначала проверяем качество текста, затем измеряем скорость работы. В отчёте должны остаться только технические события. Личные разговоры никуда не отправляются.",
        "Да, да, этот пример специально содержит повторение. У реки стоит высокий старый дом. На столе лежат книга, карандаш и карта. Завтра мы вернёмся к обсуждению и проверим каждую деталь.",
        "Анна Смирнова открыла проект в GitHub и посмотрела pull request. После проверки можно выполнить deploy. Мы продолжаем говорить без долгой остановки, чтобы проверить длинную диктовку под нагрузкой."
    ]
    private static let english = [
        "Alice Parker reviewed the documents and sent Robert Wilson a detailed reply. We discussed the new application release and checked the microphone. The beginning, middle, and ending of every recording must remain complete.",
        "Today the team is preparing an update. First we check the words, then we measure processing time. The error report contains technical events only. Private conversations never leave this computer.",
        "Yes, yes, this example deliberately repeats a word. There is an old house beside the river. A book, a pencil, and a map are on the table. Tomorrow we will return to the discussion and check every detail.",
        "Sarah Miller opened the project in GitHub and reviewed the pull request. After checking the changes, the team can deploy the release. We keep speaking to test a long recording and make sure its final sentence survives."
    ]

    private func write(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "long-quality-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func distance(_ expected: [String], _ actual: [String]) -> Int {
        var row = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var next = [i + 1]
            for (j, candidate) in actual.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (word == candidate ? 0 : 1)))
            }
            row = next
        }
        return row[actual.count]
    }
}
