import DictationCore
import LocalASR
import SwiftUI

/// Первый запуск: от установки до первой продиктованной фразы.
///
/// Порядок шагов выбран так, чтобы загрузка модели шла фоном, пока человек
/// читает и выдаёт разрешения — иначе он просто смотрел бы на индикатор.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    let onFinish: () -> Void

    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome
        case permissions
        case model
        case tryIt
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)

            Divider()

            HStack {
                if step != .welcome {
                    Button("Назад") { back() }
                }
                Spacer()
                Text("\(step.rawValue + 1) из \(Step.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                nextButton
            }
            .padding()
        }
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .permissions: permissions
        case .model: model
        case .tryIt: tryIt
        }
    }

    // MARK: - Шаги

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Диктовка, которая никуда не отправляет вашу речь")
                .font(.title2.bold())

            Text("Нажали клавишу, сказали, отпустили — текст появился там, где стоял курсор. В любом приложении.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Речь распознаётся моделью на вашем диске. Работает в самолёте.")
                } icon: {
                    Image(systemName: "airplane").foregroundStyle(.blue)
                }
                Label {
                    Text("В сеть приложение выходит только по вашей команде: скачать модель и, если включите, проверить обновления.")
                } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                }
                Label {
                    Text("Ни аккаунтов, ни аналитики, ни отчётов. Код открыт — это можно проверить.")
                } icon: {
                    Image(systemName: "lock.open").foregroundStyle(.blue)
                }
            }
            .font(.callout)

            Spacer()
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Два разрешения")
                .font(.title2.bold())

            Text("Оба выдаются в системных настройках. Мы подскажем, где именно.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                OnboardingPermission(
                    title: "Микрофон",
                    detail: "Чтобы услышать вашу речь.",
                    granted: state.microphoneGranted,
                    action: state.requestMicrophone
                )
                OnboardingPermission(
                    title: "Универсальный доступ",
                    detail: "Чтобы услышать горячую клавишу и вставить готовый текст.",
                    granted: state.accessibilityGranted,
                    action: state.requestAccessibility
                )
            }

            Text("Отдельное разрешение «Мониторинг ввода» не нужно. Приложение не запоминает и не передаёт нажатия — оно ищет только вашу горячую клавишу.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Модель распознавания")
                .font(.title2.bold())

            switch state.modelState {
            case .notInstalled:
                Text("Около 483 МБ. Скачивается один раз, дальше интернет не нужен.")
                    .foregroundStyle(.secondary)
                Button("Скачать модель") { state.installModel() }
                    .buttonStyle(.borderedProminent)

            case let .downloading(received, total):
                Text("Скачиваю…").foregroundStyle(.secondary)
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                Text("\(received / 1_000_000) из \(total / 1_000_000) МБ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Можно продолжать — загрузка не прервётся.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

            case let .verifying(checked, total):
                Text("Проверяю целостность…").foregroundStyle(.secondary)
                ProgressView(value: Double(checked), total: Double(max(total, 1)))

            case .ready:
                Label("Модель готова", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if state.isPreparingEngine {
                    Text("Готовлю к первому запуску — это занимает несколько секунд и только один раз.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case let .failed(error):
                Label("Не получилось", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(String(describing: error))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Попробовать снова") { state.installModel() }

            case .deleting:
                Text("Удаление…")
            }

            Spacer()
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Попробуйте")
                .font(.title2.bold())

            Picker("Горячая клавиша", selection: $state.hotkey) {
                ForEach(DictationHotkey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.menu)

            Text("Удерживайте \(state.hotkey.title), скажите что-нибудь и отпустите. Текст появится в поле ниже.")
                .foregroundStyle(.secondary)

            // Поле для пробы: работает даже до того, как выдан универсальный
            // доступ, потому что вставка идёт в собственное окно приложения.
            TextEditor(text: .constant(""))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if state.dictationState == .listening {
                Label("Слушаю…", systemImage: "waveform")
                    .foregroundStyle(.red)
            }

            Spacer()
        }
    }

    // MARK: - Навигация

    private var nextButton: some View {
        Button(step == .tryIt ? "Готово" : "Дальше") {
            if step == .tryIt {
                onFinish()
            } else {
                forward()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canAdvance)
    }

    private var canAdvance: Bool {
        switch step {
        case .welcome: return true
        // Дальше пускаем только когда разрешения выданы: без них следующий шаг
        // ничего не покажет, а человек решит, что приложение сломано.
        case .permissions: return state.microphoneGranted && state.accessibilityGranted
        case .model: return state.modelState.isReady
        case .tryIt: return true
        }
    }

    private func forward() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation { step = next }
        // Загрузку запускаем сразу при переходе к шагу модели, чтобы она шла,
        // пока человек читает.
        if next == .model, case .notInstalled = state.modelState {
            state.installModel()
        }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation { step = previous }
    }
}

private struct OnboardingPermission: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Выдать", action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
