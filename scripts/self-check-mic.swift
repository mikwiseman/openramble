// Помощник самопроверки: всё, чего bash про микрофон узнать не может.
//
// Три вещи, ради которых он существует:
//   • настоящий статус разрешения на микрофон (а не догадка по логам);
//   • состояние устройства ввода — то самое, от чего зависит оранжевая точка;
//   • запись живого голоса в файл, который потом уходит в распознавание.
//
// Всё, что печатается в stdout, — строки вида `ключ=значение`: их разбирает
// self-check.sh. Человеческие объяснения печатает он, не этот файл.
//
// Собирается и запускается из scripts/self-check.sh, руками не нужен.

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Коды возврата

// Разные причины — разные коды: вызывающий обязан различать «человек запретил»
// и «человека ещё не спрашивали», иначе он посоветует не то.
enum ExitCode: Int32 {
    case ok = 0
    case denied = 3
    case restricted = 4
    case notDetermined = 5
    case noInputDevice = 6
    case recordingFailed = 7
    case usage = 64
}

func emit(_ key: String, _ value: String) {
    print("\(key)=\(value)")
}

func die(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code.rawValue)
}

/// Сказать человеку прямо на экран, минуя перенаправления.
///
/// Обычный вывод этой программы вызывающий скрипт забирает в файл — иначе
/// `ключ=значение` пришлось бы выковыривать с экрана. Но одна строка адресована
/// не скрипту, а человеку, и она обязана дойти именно до него: если он её не
/// увидит, он начнёт говорить не в тот момент.
func tell(_ message: String) {
    guard let terminal = FileHandle(forWritingAtPath: "/dev/tty") else {
        FileHandle.standardError.write(Data(message.utf8))
        return
    }
    terminal.write(Data(message.utf8))
    try? terminal.close()
}

// MARK: - Разрешение

func permissionName(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

func permissionCode(_ status: AVAuthorizationStatus) -> ExitCode {
    switch status {
    case .authorized: return .ok
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notDetermined
    @unknown default: return .denied
    }
}

func reportPermission() -> Never {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    emit("permission", permissionName(status))
    exit(permissionCode(status).rawValue)
}

/// Спросить разрешение системным окном.
///
/// Здесь нарочно нет своего таймаута: окно висит ровно столько, сколько человек
/// на него не смотрит. Ограничение по времени ставит вызывающий скрипт — так
/// оно одно на все вызовы и его видно в одном месте.
func requestPermission() -> Never {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    guard status == .notDetermined else {
        // Спрашивать второй раз бессмысленно: система молча ответит тем же.
        emit("permission", permissionName(status))
        exit(permissionCode(status).rawValue)
    }

    let waiter = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in waiter.signal() }
    waiter.wait()

    let answered = AVCaptureDevice.authorizationStatus(for: .audio)
    emit("permission", permissionName(answered))
    exit(permissionCode(answered).rawValue)
}

// MARK: - Устройство ввода

func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
    )
    guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return device
}

func deviceName(_ device: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { return "имя недоступно" }
    return name as String
}

/// Слушает ли устройство хоть кто-нибудь в системе.
///
/// Это ровно то свойство, по которому macOS зажигает оранжевую точку. Оно про
/// всю систему, а не про нас: если точка горит после нашей записи, виноваты
/// можем быть и не мы — поэтому вызывающий снимает показание ещё и до записи.
func isRunningSomewhere(_ device: AudioDeviceID) -> Bool? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
    guard status == noErr else { return nil }
    return value != 0
}

func reportDevice() -> Never {
    guard let device = defaultInputDevice() else {
        die("Система не сообщила устройство ввода по умолчанию.", .noInputDevice)
    }
    emit("device", deviceName(device))
    guard let running = isRunningSomewhere(device) else {
        die("Устройство есть, но его состояние прочитать не вышло.", .noInputDevice)
    }
    emit("running", running ? "yes" : "no")
    exit(ExitCode.ok.rawValue)
}

// MARK: - Запись

/// Флаг, который ставит один поток, а читает другой.
final class Flag {
    private let lock = NSLock()
    private var value = false

    func raise() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Файл записи и счётчики к нему.
///
/// Кадры приходят с потока звукового движка, а закрывается файл с главного —
/// замок нужен ровно для этого стыка.
final class Take {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var closed = false

    private(set) var frames: AVAudioFramePosition = 0
    private(set) var peak: Float = 0
    private(set) var sumOfSquares: Double = 0
    /// Когда пришёл первый настоящий кадр звука — по нему меряется холодный
    /// старт микрофона, то самое время, за которое срезается первое слово.
    private(set) var firstFrameAt: Date?
    /// Первая ошибка записи. Молчать о ней нельзя: файл будет короче речи.
    private(set) var writeError: String?

    init(url: URL, format: AVAudioFormat) throws {
        // 16 бит на отсчёт — обычный WAV, который прочитает что угодно.
        // Частота и число каналов остаются родными для устройства: приводит их
        // к 16 кГц уже AudioFileReader, тем же кодом, что и в приложении.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let file else { return }
        if firstFrameAt == nil { firstFrameAt = Date() }

        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) {
                let sample = abs(channel[index])
                if sample > peak { peak = sample }
                sumOfSquares += Double(sample) * Double(sample)
            }
        }

        do {
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            writeError = writeError ?? String(describing: error)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        file = nil
    }

    var rms: Double {
        guard frames > 0 else { return 0 }
        return (sumOfSquares / Double(frames)).squareRoot()
    }
}

func record(path: String, limit: Double) -> Never {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    guard status == .authorized else {
        // Сюда мы попадаем, только если вызывающий не проверил разрешение. Своё
        // системное окно тут не показываем: человек его не ждёт и не поймёт.
        emit("permission", permissionName(status))
        die("Записывать без разрешения нельзя.", permissionCode(status))
    }

    guard let device = defaultInputDevice() else {
        die("Нет устройства ввода: микрофон не подключён или отключён в системе.", .noInputDevice)
    }
    emit("device", deviceName(device))

    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
        die("Микрофон отдаёт пустой формат — записывать нечего.", .noInputDevice)
    }
    emit("format", "\(Int(format.sampleRate))/\(format.channelCount)")

    let take: Take
    do {
        take = try Take(url: url, format: format)
    } catch {
        die("Файл записи не открылся: \(error)", .recordingFailed)
    }

    input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
        take.append(buffer)
    }

    let startedAt = Date()
    do {
        engine.prepare()
        try engine.start()
    } catch {
        input.removeTap(onBus: 0)
        take.close()
        die("Звуковой движок не запустился: \(error.localizedDescription)", .recordingFailed)
    }

    // Единственная строка, которую этот файл говорит человеку, — и она здесь
    // потому, что раньше сказать её некому: микрофон начинает слышать именно
    // сейчас, а не когда скрипт печатал задание. Слово, сказанное до этой
    // строки, в запись не попадёт.
    tell("  ● Идёт запись — говорите. Enter, когда закончите.\n")

    // Останавливаемся по Enter. Предел по времени существует, чтобы проверка не
    // висела вечно, если человек отошёл: он не «страховка», он назван в отчёте.
    let stop = DispatchSemaphore(value: 0)
    let endOfInput = Flag()
    DispatchQueue.global().async {
        if readLine(strippingNewline: true) == nil { endOfInput.raise() }
        stop.signal()
    }
    let reachedLimit = stop.wait(timeout: .now() + limit) == .timedOut
    // Кончившийся стандартный ввод — не «человек нажал Enter». Разница важна:
    // в первом случае записи не было вовсе, и списать пустоту на микрофон
    // значило бы соврать.
    let stopReason = reachedLimit ? "limit" : (endOfInput.isRaised ? "eof" : "enter")

    engine.stop()
    input.removeTap(onBus: 0)
    take.close()

    if let writeError = take.writeError {
        die("Запись оборвалась: \(writeError)", .recordingFailed)
    }

    // Сколько микрофон был включён — не то же самое, что длина записи. Их
    // расхождение и есть ответ на вопрос «человек нажал слишком быстро или
    // вход молчит», и решать это должен вызывающий, а не мы.
    let wall = Date().timeIntervalSince(startedAt)
    let startup = take.firstFrameAt.map { $0.timeIntervalSince(startedAt) }
    emit("startup", startup.map { String(format: "%.3f", $0) } ?? "нет")
    emit("duration", String(format: "%.3f", Double(take.frames) / format.sampleRate))
    emit("wall", String(format: "%.3f", wall))
    emit("peak", String(format: "%.4f", take.peak))
    emit("rms", String(format: "%.4f", take.rms))
    emit("stop_reason", stopReason)
    emit("file", url.path)

    // Отказом считается только молчание при работавшем движке. Мгновенно
    // остановленная запись — это про человека, а не про микрофон, и объявлять
    // её отказом железа значит послать чинить исправное.
    if take.frames == 0, wall >= 2 {
        die(String(format: "Микрофон был включён %.1f с и не отдал ни одного кадра.", wall), .recordingFailed)
    }
    exit(ExitCode.ok.rawValue)
}

// MARK: - Разбор аргументов

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "permission":
    reportPermission()
case "request":
    requestPermission()
case "device":
    reportDevice()
case "record":
    guard arguments.count == 3, let limit = Double(arguments[2]), limit > 0 else {
        die("Использование: self-check-mic record <файл.wav> <предел секунд>", .usage)
    }
    record(path: arguments[1], limit: limit)
default:
    die("Команды: permission | request | device | record <файл.wav> <предел секунд>", .usage)
}
