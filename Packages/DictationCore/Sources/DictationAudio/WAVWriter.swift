import Foundation

/// Запись звука в WAV по ходу диктовки.
///
/// Пишем на диск, а не копим в памяти: часовая диктовка — это больше сотни
/// мегабайт, и файл заодно переживает падение приложения и позволяет повторить
/// распознавание, если оно сорвалось.
///
/// Заголовок WAV содержит размеры, которые известны только в конце, поэтому
/// сначала пишется заготовка, а по завершении размеры проставляются на место.
public final class WAVWriter: @unchecked Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case cannotCreateFile(String)
        case writeFailed(String)
        case notOpen
    }

    private let url: URL
    private let sampleRate: Int
    private let channels: Int
    private let bitsPerSample = 16

    private var handle: FileHandle?
    private var bytesWritten: Int = 0
    private let lock = NSLock()

    public init(url: URL, sampleRate: Int = 16_000, channels: Int = 1) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var fileURL: URL { url }

    /// Длительность записанного на данный момент.
    public var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let bytesPerFrame = channels * bitsPerSample / 8
        guard bytesPerFrame > 0, sampleRate > 0 else { return 0 }
        return Double(bytesWritten / bytesPerFrame) / Double(sampleRate)
    }

    /// Создать файл и записать заготовку заголовка.
    public func open() throws {
        lock.lock()
        defer { lock.unlock() }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard FileManager.default.createFile(atPath: url.path, contents: header(dataBytes: 0)) else {
            throw Failure.cannotCreateFile(url.path)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            self.handle = handle
            bytesWritten = 0
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Дописать порцию звука.
    ///
    /// Вход — Float32 в диапазоне [-1, 1], на диск идёт 16-битный PCM:
    /// вдвое компактнее и ровно то, что ожидает распознавание.
    public func append(_ samples: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw Failure.notOpen }

        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Закрыть файл, проставив в заголовке настоящие размеры.
    @discardableResult
    public func close() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw Failure.notOpen }
        // Дескриптор освобождается в любом случае. Иначе неудачное закрытие
        // оставляло бы файл открытым навсегда: writer после этого недоступен, а
        // закрыть его больше некому — за день диктовки так вычерпывается лимит
        // открытых файлов процесса.
        defer { self.handle = nil }

        do {
            try handle.synchronize()
            // Размеры известны только сейчас — переписываем заголовок целиком.
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(dataBytes: bytesWritten))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw Failure.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// Прервать запись и удалить файл — пользователь отменил диктовку.
    public func discard() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Заголовок WAV на 44 байта.
    private func header(dataBytes: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1) // PCM без сжатия
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))

        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(dataBytes))
        return data
    }
}
