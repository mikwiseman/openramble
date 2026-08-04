import AVFoundation
import AppKit
import DictationCore
import Foundation

// MARK: - Разрешения

/// Разрешения, без которых диктовка не работает.
@MainActor
public enum Permissions {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
    }

    /// Универсальный доступ: нужен и для горячей клавиши, и для вставки текста.
    ///
    /// Отдельное разрешение «Мониторинг ввода» не требуется — системный монитор
    /// событий работает под этим же доступом.
    public static var accessibility: Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Запросить доступ, показав системное окно.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // Ключ берём строкой: системная константа объявлена изменяемой
        // переменной и не проходит проверку потокобезопасности Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public static var microphone: Status {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .denied
    }

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    public static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}

/// Чтение разрешений.
///
/// За протоколом — потому что настоящие ответы зависят от того, что человек
/// когда-то разрешил (в тесте — тестовому раннеру), а не от проверяемой логики.
@MainActor
public protocol PermissionReading {
    var accessibilityGranted: Bool { get }
    var microphoneGranted: Bool { get }
}

@MainActor
public struct SystemPermissions: PermissionReading {
    public init() {}
    public var accessibilityGranted: Bool { Permissions.accessibility == .granted }
    public var microphoneGranted: Bool { Permissions.microphone == .granted }
}

/// Состояние именно живого процесса, а не положение переключателя в Settings.
///
/// macOS может показать включённую старую TCC-запись, которая не совпадает с
/// designated requirement текущего бинарника. `AXIsProcessTrusted()` тогда
/// остаётся false, и это единственный авторитетный ответ для работающего app.
public enum AccessibilityPermissionState: Sendable, Equatable {
    case denied
    case waitingForSettings
    case restartRequired
    case repairRequired
    case repairing
    case failed(String)
    case granted
}

@MainActor
public protocol AccessibilityManaging {
    @discardableResult
    func requestAccess() -> Bool
    func openSettings()
    func revealApplication()
    func resetAccess() async throws
    func relaunchApplication() async throws
}

public enum AccessibilityRecoveryError: LocalizedError, Equatable {
    case missingBundleIdentifier
    case resetFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            return "The app has no bundle identifier."
        case let .resetFailed(status, output):
            let suffix = output.isEmpty ? "" : " \(output)"
            return "tccutil exited with code \(status).\(suffix)"
        }
    }
}

/// Поддерживаемый recovery-путь: официальный AX API, System Settings,
/// `tccutil` по явной команде пользователя и полноценный relaunch процесса.
/// TCC.db приложение не читает и не изменяет напрямую.
@MainActor
public struct SystemAccessibilityManager: AccessibilityManaging {
    public init() {}

    public func requestAccess() -> Bool {
        Permissions.requestAccessibility()
    }

    public func openSettings() {
        Permissions.openAccessibilitySettings()
    }

    public func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    public func resetAccess() async throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw AccessibilityRecoveryError.missingBundleIdentifier
        }

        // Ожидание завершения — через terminationHandler, а не waitUntilExit:
        // синхронное ожидание на main actor замораживало бы интерфейс на всё
        // время работы tccutil.
        let result: (status: Int32, message: String) = try await withCheckedThrowingContinuation {
            continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleIdentifier]
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (finished.terminationStatus, message))
            }
            do {
                try process.run()
            } catch {
                // Процесс не запустился — terminationHandler не сработает.
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard result.status == 0 else {
            throw AccessibilityRecoveryError.resetFailed(result.status, result.message)
        }
    }

    public func relaunchApplication() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        )
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Звуки

/// Короткие сигналы начала и конца записи.
///
/// Тип целиком привязан к главному потоку намеренно. Методы протокола
/// `Sounding` асинхронные и не наследуют исполнителя вызывающего: без этой
/// пометки тело выполнялось бы на общем пуле, а обращение к состоянию главного
/// потока оттуда роняет приложение при первом же нажатии клавиши.
@MainActor
public struct SystemSounds: Sounding {
    private let enabled: @MainActor () -> Bool

    public init(enabled: @escaping @MainActor () -> Bool = { true }) {
        self.enabled = enabled
    }

    public func playStart() async {
        guard enabled() else { return }
        NSSound(named: "Morse")?.play()
    }

    public func playStop() async {
        guard enabled() else { return }
        NSSound(named: "Pop")?.play()
    }
}

// MARK: - Пути приложения

/// Где приложение держит свои файлы.
///
/// Корень задаётся снаружи: тест обязан работать во временной папке, а не в
/// настоящем Application Support человека, который в этот момент диктует.
public struct AppPaths: Sendable {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Обычное расположение — Application Support текущего пользователя.
    ///
    /// Сам каталог здесь не создаётся: его создаст первый же `support()` вместе
    /// со своей папкой. Отказ файловой системы должен быть виден там, где мы
    /// собираемся писать, а не при вычислении имени места.
    public static func standard() -> AppPaths {
        // Для Application Support в домене пользователя список всегда ровно из
        // одного элемента. Запасного пути на этот случай нет намеренно:
        // подставить сюда что-то другое значило бы писать данные не туда.
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            preconditionFailure("The system did not report the Application Support location")
        }
        return AppPaths(root: base)
    }

    /// Корень данных приложения.
    public func support() throws -> URL {
        let directory = root.appending(path: "WaiDictation", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func models() throws -> URL {
        try support().appending(path: "Models", directoryHint: .isDirectory)
    }

    /// Куда пишутся записи во время диктовки.
    ///
    /// Файл живёт ровно до конца распознавания и сразу удаляется — голос
    /// пользователя не должен оставаться на диске.
    public func takes() throws -> URL {
        let directory = try support().appending(path: "Takes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(directory)
        return directory
    }

    /// WAV, сохранённые только после технической ошибки или process kill.
    public func audioRecovery() throws -> URL {
        let directory = try support().appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(directory)
        return directory
    }


    /// Записи и восстановленные тексты — не то, что стоит хранить в резервных
    /// копиях: это содержимое речи пользователя.
    ///
    /// Ошибка не проглатывается. Молча уехавшая в бэкап диктовка — ровно то,
    /// чего человек от приватного продукта не ждёт, и узнать об этом ему было бы
    /// неоткуда.
    private static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}
