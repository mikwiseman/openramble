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
public struct SystemSounds: Sounding {
    private let enabled: @Sendable () -> Bool

    public init(enabled: @escaping @Sendable () -> Bool = { true }) {
        self.enabled = enabled
    }

    public func playStart() async {
        guard enabled() else { return }
        await MainActor.run { NSSound(named: "Morse")?.play() }
    }

    public func playStop() async {
        guard enabled() else { return }
        await MainActor.run { NSSound(named: "Pop")?.play() }
    }
}

// MARK: - Сохранение несостоявшейся вставки

/// Складывает текст, который не удалось вставить.
///
/// Это последняя страховка: распознанное нельзя терять из-за того, что
/// приложение-получатель оказалось недоступно.
public struct RecoveryStore: RecoveryStoring {
    private let directory: URL
    /// Сколько файлов держать. Приватный продукт не должен копить бессрочный
    /// архив всего, что было сказано.
    private let keepLast = 20
    private let maximumAge: TimeInterval = 7 * 24 * 3600

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ text: String) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appending(path: "dictation-\(stamp).txt", directoryHint: .notDirectory)
        try Data(text.utf8).write(to: url, options: .atomic)

        prune()
        return url
    }

    /// Убрать старые записи: и по возрасту, и по количеству.
    private func prune() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let now = Date()
        var survivors: [(url: URL, date: Date)] = []

        for entry in entries where entry.pathExtension == "txt" {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > maximumAge {
                try? FileManager.default.removeItem(at: entry)
            } else {
                survivors.append((entry, date))
            }
        }

        guard survivors.count > keepLast else { return }
        for item in survivors.sorted(by: { $0.date > $1.date }).dropFirst(keepLast) {
            try? FileManager.default.removeItem(at: item.url)
        }
    }
}

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

    /// Куда пишутся записи во время диктовки. Файл живёт до успешной вставки.
    public static func takes() throws -> URL {
        let directory = try support().appending(path: "Takes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func recovery() throws -> URL {
        try support().appending(path: "Recovered", directoryHint: .isDirectory)
    }
}
