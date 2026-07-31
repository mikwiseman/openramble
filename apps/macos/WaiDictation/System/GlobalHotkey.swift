import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Клавиша, по которой начинается диктовка.
///
/// Все варианты — модификаторы: их можно удерживать, и они не отнимают у
/// приложений обычные сочетания.
public enum DictationHotkey: String, CaseIterable, Sendable, Codable {
    case fn
    case rightCommand
    case rightOption
    case leftControl

    public var title: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightCommand: return "Правый Command"
        case .rightOption: return "Правый Option"
        case .leftControl: return "Левый Control"
        }
    }

    /// Флаг, по которому клавиша распознаётся в событии.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightCommand: return .command
        case .rightOption: return .option
        case .leftControl: return .control
        }
    }

    /// Код конкретной физической клавиши.
    ///
    /// Нужен, чтобы отличить правый Command от левого: флаг у них один и тот же.
    var keyCode: CGKeyCode? {
        switch self {
        case .fn: return CGKeyCode(kVK_Function)
        case .rightCommand: return CGKeyCode(kVK_RightCommand)
        case .rightOption: return CGKeyCode(kVK_RightOption)
        case .leftControl: return CGKeyCode(kVK_Control)
        }
    }
}

/// Слежение за горячей клавишей во всех приложениях.
///
/// Работает через системный монитор событий и требует только разрешение
/// «Универсальный доступ» — то же самое, что нужно для вставки текста.
/// Отдельное разрешение «Мониторинг ввода» не запрашивается.
///
/// Монитор видит нажатия клавиш, но ничего не запоминает и не передаёт: он
/// сравнивает событие с выбранной клавишей и Escape, всё остальное отбрасывает.
@MainActor
public final class GlobalHotkeyMonitor {
    private let logger = Logger(subsystem: "is.waiwai.dictation", category: "hotkey")

    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public var onDoubleTap: (() -> Void)?
    public var onEscape: (() -> Void)?

    public private(set) var hotkey: DictationHotkey = .rightCommand
    public private(set) var isRunning = false

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var isHeld = false
    private var lastTapAt: Date?

    /// Промежуток, в пределах которого второе нажатие считается двойным.
    private let doubleTapWindow: TimeInterval = 0.35

    public init() {}

    public func setHotkey(_ hotkey: DictationHotkey) {
        self.hotkey = hotkey
        isHeld = false
        lastTapAt = nil
    }

    /// Запустить слежение.
    ///
    /// Вызывается повторно при каждой проверке разрешений: система выдаёт
    /// монитору события только после того, как пользователь дал доступ, и
    /// зарегистрироваться нужно уже после этого. Без повторного запуска
    /// клавиша молчала бы до перезапуска приложения.
    ///
    /// Но если слежение уже идёт, перезапускать его нельзя. Проверка разрешений
    /// тикает раз в секунду, а перезапуск сбрасывал бы память о зажатой клавише —
    /// и отпускание, случившееся после тика, терялось бы. Диктовка при этом
    /// оставалась бы включённой: микрофон горит, запись идёт, остановить нечем.
    public func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else { return }

        // Обработчики вызываются на главном потоке, поэтому входим в него
        // напрямую. Обёртка в отдельные задачи не гарантировала бы порядок:
        // нажатие и отпускание могли прийти в обратной последовательности, и
        // диктовка осталась бы включённой.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyDown(event) }
        }
        isRunning = flagsMonitor != nil
    }

    public func stop() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
        isRunning = false
        isHeld = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let matchesKey: Bool
        if let expected = hotkey.keyCode {
            matchesKey = CGKeyCode(event.keyCode) == expected
        } else {
            matchesKey = true
        }
        guard matchesKey else { return }

        let pressed = event.modifierFlags.contains(hotkey.flag)

        if pressed, !isHeld {
            isHeld = true
            let now = Date()
            if let lastTapAt, now.timeIntervalSince(lastTapAt) < doubleTapWindow {
                self.lastTapAt = nil
                onDoubleTap?()
            } else {
                self.lastTapAt = now
                onPress?()
            }
        } else if !pressed, isHeld {
            isHeld = false
            onRelease?()
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Escape отменяет диктовку — но только пока она идёт. В остальное время
        // это обычная клавиша, и трогать её нельзя.
        guard event.keyCode == UInt16(kVK_Escape) else { return }
        onEscape?()
    }
}
