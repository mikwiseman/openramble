import AppKit
import DictationCore
import SwiftUI

/// Меню в строке меню — весь интерфейс приложения в покое.
///
/// Лежит отдельно от точки входа намеренно: `WaiDictationApp.swift` не
/// компилируется в тестовую цель (там `@main`), а всё, что человек здесь видит,
/// проверяться должно.
struct MenuContent: View {
    @ObservedObject var state: AppState
    // Отдельная подписка: Sparkle сообщает о своих изменениях сам, через
    // AppState они бы не дошли.
    @ObservedObject var updater: SparkleUpdater
    let showOnboarding: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(
            MenuBarStatus.statusLine(
                state: state.dictationState,
                isDictationReady: state.isDictationReady,
                hotkeyTitle: state.hotkey.title
            )
        )

        if !state.isDictationReady {
            Divider()
            setupHints
            Button("Пройти настройку заново") {
                showOnboarding()
                openWindow(id: "onboarding")
            }
        }

        Divider()

        Button("Проверить обновления…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        Button("Настройки…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)

        Button("Завершить") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var setupHints: some View {
        if !state.accessibilityGranted {
            Button("Выдать универсальный доступ") { state.requestAccessibility() }
        }
        if !state.microphoneGranted {
            Button("Разрешить микрофон") { state.requestMicrophone() }
        }
        if !state.modelState.isReady {
            Button("Скачать модель (483 МБ)") { state.installModel() }
        }
    }
}
