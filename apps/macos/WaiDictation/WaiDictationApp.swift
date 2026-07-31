import DictationCore
import SwiftUI

@main
struct WaiDictationApp: App {
    @StateObject private var state = AppState()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Приложение живёт в строке меню: у диктовки нет своего окна, она
        // работает поверх того, где сейчас пользователь.
        MenuBarExtra {
            MenuContent(state: state, showOnboarding: { onboardingCompleted = false })
        } label: {
            Image(systemName: menuIcon)
        }

        Window("Добро пожаловать", id: "onboarding") {
            if !onboardingCompleted {
                OnboardingView(state: state) { onboardingCompleted = true }
            }
        }
        .windowResizability(.contentSize)

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
    let showOnboarding: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        statusLine

        if !state.isDictationReady {
            Divider()
            setupHints
            Button("Пройти настройку заново") {
                showOnboarding()
                openWindow(id: "onboarding")
            }
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
