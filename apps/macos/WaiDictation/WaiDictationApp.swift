import DictationCore
import SwiftUI

@main
struct WaiDictationApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // Приложение живёт в строке меню: у диктовки нет своего окна, она
        // работает поверх того, где сейчас пользователь.
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: menuIcon)
        }

        Settings {
            SettingsView(state: state)
        }
    }

    private var menuIcon: String {
        switch state.dictationState {
        case .listening: return "mic.fill"
        case .transcribing, .inserting: return "waveform"
        case .preparing, .idle: return state.isDictationReady ? "mic" : "mic.slash"
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        statusLine

        if !state.isDictationReady {
            Divider()
            setupHints
        }

        Divider()

        Button("Настройки…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)

        Button("Завершить") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state.dictationState {
        case .idle:
            if state.isDictationReady {
                Text("Удерживайте \(state.hotkey.title) и говорите")
            } else {
                Text("Нужна настройка")
            }
        case .preparing:
            Text("Включаю микрофон…")
        case .listening:
            Text("Слушаю")
        case .transcribing:
            Text("Распознаю…")
        case .inserting:
            Text("Вставляю текст")
        }
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
