import XCTest
@testable import DictationAudio

/// Очередь кадров между звуковым потоком и диском.
///
/// Оба дефекта, которые здесь стерегутся, беззвучны: запись получается, файл
/// открывается, и только речь в нём — не та, что была сказана. Проверяется
/// настоящей записью в WAV, потому что перемешать кадры может именно она.
final class FrameSinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Собиратель кадров, повторяющий работу микрофона: медленный и на акторе.
    private actor Collector {
        private(set) var received: [Float] = []

        func consume(_ samples: [Float]) async {
            // Настоящая запись на диск не мгновенна, и именно на этой паузе
            // задачи обгоняли друг друга.
            try? await Task.sleep(for: .microseconds(50))
            received.append(contentsOf: samples)
        }
    }

    func testFramesArriveInTheOrderTheyWereProduced() async throws {
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = await sink.start { await collector.consume($0) }

        // 400 кадров подряд, каждый помечен своим номером.
        let expected = (0..<400).map { Float($0) }
        for value in expected { enqueue([value]) }

        await sink.finish()

        let received = await collector.received
        XCTAssertEqual(received, expected, "Кадры обязаны лечь в файл в том же порядке, в каком прозвучали")
    }

    func testOrderHoldsWhenFramesComeFromTheAudioThread() async throws {
        // Колбэк движка приходит не с того потока, где живёт актор.
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = await sink.start { await collector.consume($0) }

        let count = 300
        let done = expectation(description: "звуковой поток отдал все кадры")
        Thread.detachNewThread {
            for index in 0..<count { enqueue([Float(index)]) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)

        await sink.finish()

        let received = await collector.received
        XCTAssertEqual(received, (0..<count).map { Float($0) })
    }

    func testFinishWaitsForTheLastFrame() async throws {
        // Хвост фразы: человек отпускает клавишу ровно на последнем слове.
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = await sink.start { await collector.consume($0) }

        for index in 0..<200 { enqueue([Float(index)]) }
        await sink.finish()

        let received = await collector.received
        XCTAssertEqual(received.count, 200, "После остановки в очереди не должно остаться ни одного кадра")
        XCTAssertEqual(received.last, 199, "Последнее слово теряется как раз здесь")
    }

    func testTailSurvivesIntoTheWAVFile() async throws {
        // То же самое, но до самого конца: файл на диске обязан содержать всё.
        let url = directory.appending(path: "take.wav")
        let writer = WAVWriter(url: url, sampleRate: 16_000, channels: 1)
        try writer.open()

        let sink = FrameSink()
        let enqueue = await sink.start { samples in
            try? await Task.sleep(for: .microseconds(50))
            try? writer.append(samples)
        }

        // Секунда звука кадрами по 512 сэмплов, как отдаёт движок.
        let frameCount = 16_000 / 512
        for _ in 0..<frameCount { enqueue(Array(repeating: 0.25, count: 512)) }

        await sink.finish()
        let closed = try writer.close()

        let size = try FileManager.default.attributesOfItem(atPath: closed.path)[.size] as? Int
        let expectedBytes = 44 + frameCount * 512 * 2
        XCTAssertEqual(size, expectedBytes, "Файл обязан содержать все кадры, включая последний")
    }

    func testCancelDropsTheQueueInsteadOfWritingIt() async throws {
        // Диктовку отменили — дописывать нечего.
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = await sink.start { await collector.consume($0) }

        for index in 0..<500 { enqueue([Float(index)]) }
        await sink.cancel()

        let received = await collector.received
        XCTAssertLessThan(received.count, 500, "Отмена не должна ждать всю очередь")
    }

    func testEnqueueAfterFinishIsHarmless() async throws {
        // Кадр, вышедший из железа одновременно с остановкой, приходит уже
        // после закрытия очереди. Падать на этом нельзя.
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = await sink.start { await collector.consume($0) }

        enqueue([1])
        await sink.finish()
        enqueue([2])

        let received = await collector.received
        XCTAssertEqual(received, [1])
    }
}
