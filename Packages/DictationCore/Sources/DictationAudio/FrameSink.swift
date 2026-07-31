import Foundation

/// Очередь кадров между звуковым потоком и записью на диск.
///
/// Звуковой движок зовёт свой колбэк на собственном потоке реального времени:
/// там нельзя ни ждать, ни писать в файл. Кадр нужно куда-то отдать за
/// наносекунды — и при этом не потерять ни порядок, ни последние кадры.
///
/// Оба требования появились из настоящих дефектов. Каждый кадр раньше уезжал на
/// диск отдельной задачей — порядок их выполнения ничем не задан, и запись
/// могла перемешаться сама с собой. А остановка закрывала файл, не дожидаясь
/// очереди, — пропадало последнее слово, ровно то, на котором человек отпускает
/// клавишу.
///
/// Тип отделён от микрофона намеренно: так его можно проверить без звукового
/// железа, которого в тестовой среде нет.
actor FrameSink {
    private var frames: AsyncStream<[Float]>.Continuation?
    private var drain: Task<Void, Never>?

    /// Начать приём кадров.
    ///
    /// Возвращает функцию для звукового потока: она только кладёт кадр в
    /// очередь и сразу возвращается. Разбирает очередь одна задача подряд —
    /// в этом и состоит гарантия порядка.
    func start(consume: @escaping @Sendable ([Float]) async -> Void) -> @Sendable ([Float]) -> Void {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        frames = continuation
        drain = Task {
            for await samples in stream {
                await consume(samples)
            }
        }
        return { samples in continuation.yield(samples) }
    }

    /// Закрыть очередь и дождаться, пока последний кадр окажется на диске.
    func finish() async {
        frames?.finish()
        frames = nil
        await drain?.value
        drain = nil
    }

    /// Бросить очередь, не дожидаясь записи, — диктовку отменили.
    func cancel() {
        frames?.finish()
        frames = nil
        drain?.cancel()
        drain = nil
    }
}
