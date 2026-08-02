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
                isHandsFreeActive: state.isHandsFreeActive,
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

        // Текст, который не удалось вставить, сохраняется на диск — и до сих
        // пор человеку сообщали только сам факт. «Он сохранён» без ответа на
        // «где» почти бесполезно: файл лежит в служебной папке, которую в
        // Finder ещё надо суметь открыть. А это единственная копия сказанного.
        if let file = state.recoveredFile {
            Divider()
            Button("Показать спасённый текст") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
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
        // Через тот же тип, что и оба экрана. Раньше меню знало про модель один
        // булев «готова или нет» и предлагало «Скачать» даже посреди загрузки —
        // нажатие уходило в никуда, а первая строка меню при этом говорила
        // «Нужна настройка», ни словом не упоминая, что загрузка идёт.
        let model = ModelStatus.make(
            state: state.modelState,
            isPreparingEngine: state.isPreparingEngine,
            place: .settings
        )
        if !state.modelState.isReady {
            Text(model.progressLabel.map { "\(model.title) — \($0)" } ?? model.title)

            ForEach(model.actions.filter { $0 != .delete }, id: \.self) { action in
                Button(action.title) {
                    switch action {
                    case .install, .retry: state.installModel()
                    case .delete: break
                    }
                }
            }
        }
    }
}
