import AVFoundation
import CryptoKit
import Foundation

/// Голоса, которыми синтезируется звук для сквозных тестов.
///
/// Русский системный голос в macOS ровно один, поэтому «разные дикторы» здесь
/// недостижимы: синтез даёт ровную речь без пауз, оговорок и шума. Это главное
/// ограничение всей проверки, и оно записано в отчёте.
enum SpeechVoice: String, Sendable {
    case russian = "Milena"
    case english = "Samantha"
}

enum FixtureFailure: Error, CustomStringConvertible {
    case toolMissing(String)
    case voiceMissing(String)
    case toolFailed(tool: String, status: Int32, output: String)
    case unreadable(String)

    var description: String {
        switch self {
        case let .toolMissing(tool):
            return "в системе нет \(tool) — синтезировать звук нечем"
        case let .voiceMissing(voice):
            return "в системе не установлен голос \(voice): Системные настройки → Универсальный доступ → Речь"
        case let .toolFailed(tool, status, output):
            return "\(tool) вернул \(status): \(output)"
        case let .unreadable(reason):
            return "не читается запись: \(reason)"
        }
    }
}

/// Звук для сквозных тестов: синтезируется системным голосом macOS.
///
/// Готовые файлы кэшируются между прогонами. `say` детерминирован — одна и та
/// же фраза даёт побайтово одинаковый файл, — поэтому кэш безопасен, а ключом
/// служит хэш голоса и текста: правка текста даёт новый файл, устаревший кэш
/// подсунуть нечем.
actor SpeechFixtures {
    static let shared = SpeechFixtures()

    private let sampleRate = 16_000

    private let cache = FileManager.default.temporaryDirectory
        .appending(path: "wai-dictation-e2e-audio", directoryHint: .isDirectory)

    /// Синтезировать фразу и вернуть WAV в формате диктовки: моно, 16 кГц, 16 бит.
    func speech(_ text: String, voice: SpeechVoice = .russian) throws -> URL {
        let destination = try cached(named: "\(voice.rawValue)-\(digest(voice.rawValue, text))")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        // Голос проверяется отдельно: `say` с чужим именем голоса читает текст
        // голосом по умолчанию, и вместо внятного пропуска тест получил бы
        // английскую озвучку русской фразы и непонятное падение.
        try requireVoice(voice)

        return try build(into: destination) { work in
            // Текст передаётся файлом, а не аргументом: трёхминутная фикстура в
            // командную строку не влезает, а переводы строк в аргументе теряются.
            let source = work.appending(path: "text.txt", directoryHint: .notDirectory)
            try Data(text.utf8).write(to: source)

            let aiff = work.appending(path: "speech.aiff", directoryHint: .notDirectory)
            let wav = work.appending(path: "speech.wav", directoryHint: .notDirectory)
            try Self.run("/usr/bin/say", ["-v", voice.rawValue, "-f", source.path, "-o", aiff.path])
            try Self.run(
                "/usr/bin/afconvert",
                ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
            )
            return wav
        }
    }

    /// Запись, в которой человек молчит.
    ///
    /// Не абсолютный ноль, а тихий фон около −60 dBFS: ровно это слышит микрофон
    /// в тихой комнате. На абсолютном нуле проверка была бы слабее — «модель не
    /// выдумывает фразу» надо спрашивать про настоящий шумовой пол.
    func silence(seconds: Double) throws -> URL {
        let destination = try cached(named: "silence-\(Int(seconds * 1000))ms")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        return try build(into: destination) { work in
            var generator = SystemNoise(seed: 0x5DEE_CE66_D000_0001)
            let frames = Int(Double(sampleRate) * seconds)
            let samples = (0..<frames).map { _ in generator.next() }
            let wav = work.appending(path: "silence.wav", directoryHint: .notDirectory)
            try Self.writeWAV(samples: samples, sampleRate: sampleRate, to: wav)
            return wav
        }
    }

    /// Обрезать запись до нужной длительности, не трогая формат.
    ///
    /// Нужно для проверки «нажал и сразу отпустил»: обрывок настоящей речи
    /// честнее сгенерированного щелчка.
    func truncated(_ source: URL, toSeconds seconds: Double) throws -> URL {
        let destination = try cached(
            named: "cut-\(Int(seconds * 1000))ms-\(digest("cut", source.lastPathComponent))"
        )
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let head = try Self.readSamples(from: source, limit: Int(Double(sampleRate) * seconds))
        return try build(into: destination) { work in
            let wav = work.appending(path: "cut.wav", directoryHint: .notDirectory)
            try Self.writeWAV(samples: head, sampleRate: sampleRate, to: wav)
            return wav
        }
    }

    // MARK: - Внутреннее

    /// Список установленных голосов — спрашивается у системы один раз.
    private var installedVoices: Set<String>?

    private func requireVoice(_ voice: SpeechVoice) throws {
        if installedVoices == nil {
            let listing = try Self.output(of: "/usr/bin/say", ["-v", "?"])
            // Каждая строка начинается с имени голоса, дальше идёт код языка.
            installedVoices = Set(
                listing.split(separator: "\n").compactMap {
                    $0.split(separator: " ").first.map(String.init)
                }
            )
        }
        guard installedVoices?.contains(voice.rawValue) == true else {
            throw FixtureFailure.voiceMissing(voice.rawValue)
        }
    }

    private func cached(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache.appending(path: "\(name).wav", directoryHint: .notDirectory)
    }

    /// Собрать файл во временной папке и переставить на место одним движением.
    ///
    /// Половинчатый файл в кэше был бы хуже отсутствующего: следующий прогон
    /// принял бы его за готовый.
    private func build(into destination: URL, make: (URL) throws -> URL) throws -> URL {
        let work = cache.appending(path: "build-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let produced = try make(work)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: produced, to: destination)
        return destination
    }

    private func digest(_ parts: String...) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Запустить инструмент, отбросив вывод.
    private static func run(_ tool: String, _ arguments: [String]) throws {
        _ = try output(of: tool, arguments)
    }

    /// Запустить инструмент и вернуть его вывод.
    private static func output(of tool: String, _ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw FixtureFailure.toolMissing(tool)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let errors = Pipe()
        process.standardOutput = out
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw FixtureFailure.toolFailed(tool: tool, status: -1, output: String(describing: error))
        }

        // Вывод вычитывается до ожидания: полная труба остановила бы процесс,
        // а ожидание его завершения — нас.
        let produced = out.fileHandleForReading.readDataToEndOfFile()
        let complaints = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FixtureFailure.toolFailed(
                tool: tool,
                status: process.terminationStatus,
                output: String(decoding: complaints, as: UTF8.self)
            )
        }
        return String(decoding: produced, as: UTF8.self)
    }

    /// Прочитать запись в 16-битные отсчёты.
    private static func readSamples(from url: URL, limit: Int) throws -> [Int16] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw FixtureFailure.unreadable(error.localizedDescription)
        }

        let frames = AVAudioFrameCount(min(Int(file.length), limit))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else {
            throw FixtureFailure.unreadable("в \(url.lastPathComponent) нечего читать")
        }

        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            throw FixtureFailure.unreadable(error.localizedDescription)
        }
        guard let channel = buffer.floatChannelData?[0] else {
            throw FixtureFailure.unreadable("нет данных канала")
        }

        return (0..<Int(buffer.frameLength)).map { index in
            Int16(max(-1, min(1, channel[index])) * 32_767)
        }
    }

    /// Записать WAV ровно тем же заголовком, каким его пишет диктовка.
    private static func writeWAV(samples: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data()
        let payload = samples.count * 2
        let byteRate = sampleRate * 2

        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1) // PCM без сжатия
        appendUInt16(1) // моно
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(2) // блок = один 16-битный отсчёт
        appendUInt16(16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(payload))

        data.reserveCapacity(data.count + payload)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }
}

/// Шумовой пол тихой комнаты — воспроизводимый до отсчёта.
///
/// Свой генератор, а не системный: фикстура обязана быть одинаковой в каждом
/// прогоне, иначе «модель ничего не выдумала» проверялось бы каждый раз на
/// другом звуке.
private struct SystemNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Int16 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        // ±32 из 32767 — около −60 dBFS.
        return Int16(truncatingIfNeeded: Int(state >> 40) % 65) - 32
    }
}
