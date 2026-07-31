import XCTest
@testable import LocalASR

/// Нарезка существует из-за конкретного дефекта движка: на записях длиннее его
/// внутреннего окна он молча терял целые предложения. Эти тесты стерегут,
/// чтобы нарезка сама не начала терять звук.
final class SpeechSegmenterTests: XCTestCase {
    private let sampleRate: Double = 16_000

    /// Речеподобный сигнал.
    private func speech(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { index in
            sin(Float(index) * 0.05) * amplitude
        }
    }

    private func silence(seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }

    func testShortRecordingIsNotCutAtAll() {
        let segmenter = SpeechSegmenter()
        let samples = speech(seconds: 5)

        let segments = segmenter.segments(for: samples)

        XCTAssertEqual(segments.count, 1, "Короткую запись резать незачем")
        XCTAssertEqual(segments[0].range, 0..<samples.count)
    }

    func testLongRecordingIsCut() {
        let segmenter = SpeechSegmenter(maximumDuration: 12)
        let samples = speech(seconds: 30)

        let segments = segmenter.segments(for: samples)

        XCTAssertGreaterThan(segments.count, 1, "Длинную запись обязаны разрезать")
        for segment in segments {
            XCTAssertLessThanOrEqual(
                segment.duration,
                12.5,
                "Кусок длиннее окна движка вернёт ту самую потерю речи"
            )
        }
    }

    func testNoAudioIsLostBetweenSegments() {
        // Самое важное свойство: куски обязаны покрывать запись целиком и без
        // нахлёста. Дыра здесь — это ровно тот дефект, от которого мы уходим.
        let segmenter = SpeechSegmenter(maximumDuration: 8)
        let samples = speech(seconds: 25)

        let segments = segmenter.segments(for: samples)

        XCTAssertEqual(segments.first?.range.lowerBound, 0, "Начало записи потеряно")
        XCTAssertEqual(segments.last?.range.upperBound, samples.count, "Конец записи потерян")

        for index in 1..<segments.count {
            XCTAssertEqual(
                segments[index - 1].range.upperBound,
                segments[index].range.lowerBound,
                "Между кусками \(index - 1) и \(index) пропал звук"
            )
        }
    }

    func testCutsHappenInSilenceWhenPossible() {
        // Разрез посреди слова портит распознавание обоих кусков, поэтому режем
        // по паузе, если она есть.
        let segmenter = SpeechSegmenter(maximumDuration: 10)
        var samples = speech(seconds: 8)
        samples += silence(seconds: 1.2)
        samples += speech(seconds: 8)

        let segments = segmenter.segments(for: samples)

        guard segments.count >= 2 else {
            return XCTFail("Ожидалось несколько кусков, получено \(segments.count)")
        }
        // Первый разрез должен попасть в паузу — между 8-й и 9,2-й секундой.
        let cut = Double(segments[0].range.upperBound) / sampleRate
        XCTAssertGreaterThan(cut, 7.9)
        XCTAssertLessThan(cut, 9.4, "Разрез пришёлся не на паузу")
    }

    func testHandlesRecordingWithoutAnySilence() {
        // Непрерывная речь без пауз — режем по границе куска. Разрез посреди
        // слова неприятен, но молчаливая потеря целой фразы куда хуже.
        let segmenter = SpeechSegmenter(maximumDuration: 10)
        let samples = speech(seconds: 26)

        let segments = segmenter.segments(for: samples)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.last?.range.upperBound, samples.count)
    }

    func testEmptyInputProducesNoSegments() {
        XCTAssertTrue(SpeechSegmenter().segments(for: []).isEmpty)
    }

    func testNeedsSegmentationMatchesThreshold() {
        let segmenter = SpeechSegmenter(maximumDuration: 12)

        XCTAssertFalse(segmenter.needsSegmentation(sampleCount: Int(11 * sampleRate)))
        XCTAssertTrue(segmenter.needsSegmentation(sampleCount: Int(13 * sampleRate)))
    }

    func testHourLongRecordingIsSplitIntoManageablePieces() {
        // Час — заявленный предел одной диктовки.
        let segmenter = SpeechSegmenter(maximumDuration: 12)
        let samples = speech(seconds: 3600)

        let segments = segmenter.segments(for: samples)

        XCTAssertGreaterThan(segments.count, 250)
        let total = segments.reduce(0) { $0 + ($1.range.upperBound - $1.range.lowerBound) }
        XCTAssertEqual(total, samples.count, "Час записи должен покрываться кусками целиком")
    }
}
