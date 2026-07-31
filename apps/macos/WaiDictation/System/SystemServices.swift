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

import AVFoundation

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

// Сохранение несостоявшейся вставки — `RecoveryStore` — живёт в DictationCore:
// это чистая работа с файлами, и правила ротации там покрыты тестами.

// MARK: - Пути приложения

public enum AppPaths {
    /// Корень данных приложения.
    public static func support() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "WaiDictation", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func models() throws -> URL {
        try support().appending(path: "Models", directoryHint: .isDirectory)
    }

    /// Куда пишутся записи во время диктовки.
    ///
    /// Файл живёт ровно до конца распознавания и сразу удаляется — голос
    /// пользователя не должен оставаться на диске.
    public static func takes() throws -> URL {
        let directory = try support().appending(path: "Takes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        return directory
    }

    /// Подмести записи, уцелевшие после падения или отключения питания.
    ///
    /// Обычно каталог пуст: запись удаляется сразу после распознавания. Но если
    /// приложение прервали посреди диктовки, файл останется — и без уборки
    /// пролежит там навсегда.
    public static func sweepAbandonedTakes() {
        guard let directory = try? takes(),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              )
        else { return }

        for entry in entries where entry.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Записи и восстановленные тексты — не то, что стоит хранить в резервных
    /// копиях: это содержимое речи пользователя.
    private static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    public static func recovery() throws -> URL {
        let directory = try support().appending(path: "Recovered", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        return directory
    }
}
