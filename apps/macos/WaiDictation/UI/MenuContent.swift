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

        if state.dictationState == .preparing || state.dictationState == .listening {
            Divider()
            Button("Остановить и вставить") { state.finishCurrentDictation() }
            Button("Отменить и удалить запись", role: .destructive) {
                state.cancelCurrentDictation()
            }
        }

        if !state.isDictationReady {
            Divider()
            setupHints
            Button("Пройти настройку заново") {
                showOnboarding()
                openWindow(id: "onboarding")
            }
        }

        if state.recoveredText != nil {
            Divider()
            Button("Повторить вставку") { state.retryRecoveredText() }
            Button("Скопировать текст") { state.copyRecoveredText() }
            Button("Удалить сохранённый текст", role: .destructive) {
                state.deleteRecoveredText()
            }
        }

        if state.recoveredRecording != nil {
            Divider()
            Text("Локальная запись после сбоя")
            Button("Повторить распознавание") { state.retryRecoveredRecording() }
                .disabled(!state.modelState.isReady || state.dictationState != .idle)
            Button("Удалить запись") { state.deleteRecoveredRecording() }
        }

        Divider()

        Button("Проверить обновления…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        Button("Настройки…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)

        Button("Выйти из Wai Dictation") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var setupHints: some View {
        if !state.accessibilityGranted {
            switch state.accessibilityState {
            case .denied:
                Button("Выдать универсальный доступ") { state.requestAccessibility() }
            case .waitingForSettings:
                Button("Открыть настройки доступа") { state.openAccessibilitySettings() }
            case .restartRequired:
                Button("Перезапустить для доступа") { state.restartForAccessibility() }
            case .repairRequired, .failed:
                Text("Нужно восстановить Универсальный доступ")
            case .repairing:
                Text("Восстанавливаю Универсальный доступ…")
            case .granted:
                EmptyView()
            }
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
        if state.modelState.isReady, !state.isEngineReady {
            Text("Готовлю модель к диктовке…")
        } else if !state.modelState.isReady {
            Text(model.progressLabel.map { "\(model.title) — \($0)" } ?? model.title)

            ForEach(model.actions.filter { $0 != .delete }, id: \.self) { action in
                Button(action.title) {
                    switch action {
                    case .install, .retry, .repair: state.installModel()
                    case .cancel: state.cancelModelInstall()
                    case .delete: break
                    }
                }
            }
        }
    }
}
