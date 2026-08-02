import AppKit
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
            MenuContent(
                state: state,
                updater: state.updater,
                showOnboarding: { onboardingCompleted = false }
            )
        } label: {
            Image(
                systemName: MenuBarStatus.iconName(
                    state: state.dictationState,
                    isDictationReady: state.isDictationReady
                )
            )
            // Значок — единственное постоянное присутствие приложения на
            // экране. Без ярлыка VoiceOver читает имя системного символа.
            .accessibilityLabel(
                MenuBarStatus.accessibilityLabel(
                    state: state.dictationState,
                    isDictationReady: state.isDictationReady
                )
            )
            .task {
                // Первый запуск обязан сам показать настройку. Без этого
                // приложение молча уходит в строку меню: значка в доке нет,
                // окна нет, и человек, только что перетащивший его из
                // образа, не видит вообще ничего — ни разрешений, ни модели,
                // без которых диктовка не работает.
                guard !onboardingCompleted else { return }
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
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
}
