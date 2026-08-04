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

    @Environment(\.dismiss) private var dismiss

    @State private var step: OnboardingStep = .welcome
    /// Что человек продиктовал на пробу.
    @State private var trial = ""
    /// Вручную напечатанный текст не считается пробой: ждём именно успешную
    /// вставку, случившуюся после входа на последний шаг.
    @State private var trialStartCount = 0
    @State private var showAccessibilityRepairConfirmation = false
    @FocusState private var trialFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)

            Divider()

            VStack(spacing: 6) {
                HStack {
                    if step.hasPrevious {
                        Button("Назад") { back() }
                            .accessibilityHint("Вернуться к шагу \(step.rawValue)")
                    }
                    Spacer()
                    Text(step.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(step.progressAccessibilityLabel)
                    Spacer()
                    nextButton
                }

                // Почему кнопка погашена. Без этой строки человек видит мёртвую
                // «Дальше» и не знает, чего от него ждут, — а для незрячего
                // установка на этом просто заканчивается.
                if let reason = blockReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 420)
        .confirmationDialog(
            "Восстановить Универсальный доступ?",
            isPresented: $showAccessibilityRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Сбросить доступ Wai Dictation и перезапустить", role: .destructive) {
                state.repairAccessibility()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("macOS удалит только Accessibility-записи Wai Dictation. После перезапуска доступ нужно будет выдать заново.")
        }
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
                .accessibilityAddTraits(.isHeader)

            Text("Нажали клавишу, сказали, отпустили — текст появился там, где стоял курсор. В любом приложении.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Речь распознаётся моделью на вашем диске. Работает в самолёте.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "airplane").foregroundStyle(.blue)
                }
                Label {
                    Text("В сеть приложение выходит только по вашей команде: скачать модель и, если включите, проверить обновления.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                }
                Label {
                    Text("Ни аккаунтов, ни аналитики, ни отчётов. Код открыт — это можно проверить.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.open").foregroundStyle(.blue)
                }
                Label {
                    Text("Safe beta требует Mac на Apple Silicon и macOS 14 или новее.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "cpu").foregroundStyle(.blue)
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
                .accessibilityAddTraits(.isHeader)

            Text("Оба выдаются в системных настройках. Мы подскажем, где именно.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                OnboardingPermission(
                    status: PermissionStatus(
                        title: "Микрофон",
                        detail: "Чтобы услышать вашу речь.",
                        granted: state.microphoneGranted
                    ),
                    action: state.requestMicrophone
                )
                OnboardingPermission(
                    status: PermissionStatus.accessibility(
                        state: state.accessibilityState,
                        detail: "Чтобы услышать горячую клавишу и вставить готовый текст.",
                    ),
                    action: performAccessibilityAction
                )
            }

            if needsAccessibilityRepair {
                HStack {
                    Button("Показать приложение в Finder") {
                        state.revealApplicationForAccessibility()
                    }
                    Button("Открыть Системные настройки") {
                        state.openAccessibilitySettings()
                    }
                }
                .font(.caption)
            }

            Text("Отдельное разрешение «Мониторинг ввода» не нужно. Приложение не запоминает и не передаёт нажатия — оно ищет только вашу горячую клавишу.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var needsAccessibilityRepair: Bool {
        switch state.accessibilityState {
        case .repairRequired, .failed:
            true
        default:
            false
        }
    }

    private func performAccessibilityAction() {
        switch state.accessibilityState {
        case .denied:
            state.requestAccessibility()
        case .waitingForSettings:
            state.openAccessibilitySettings()
        case .restartRequired:
            state.restartForAccessibility()
        case .repairRequired, .failed:
            showAccessibilityRepairConfirmation = true
        case .repairing, .granted:
            break
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Модель распознавания")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            ModelStatusView(
                status: ModelStatus.make(
                    state: state.modelState,
                    isPreparingEngine: state.isPreparingEngine,
                    place: .onboarding,
                    downloadMegabytes: state.remainingDownloadMegabytes
                ),
                install: state.installModel,
                cancel: state.cancelModelInstall,
                delete: state.deleteModel
            )

            Spacer()
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Попробуйте")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Picker("Горячая клавиша", selection: $state.hotkey) {
                ForEach(DictationHotkey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("Клавиша, которую надо удерживать во время диктовки")

            if let warning = state.hotkeyWarning {
                Label {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Предупреждение о клавише. \(warning)")
            }

            Text("Удерживайте \(state.hotkey.title), скажите что-нибудь и отпустите. Текст появится в поле ниже.")
                .foregroundStyle(.secondary)

            // Поле для пробы. Настоящее, с изменяемым текстом: раньше оно было
            // привязано к константе, и продиктованное в нём не появлялось
            // никогда — первая же попытка выглядела так, будто ничего не
            // работает. Курсор ставится сюда сам, иначе текст уйдёт в то окно,
            // которое было впереди до онбординга.
            TextEditor(text: $trial)
                .frame(height: 90)
                .focused($trialFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onAppear { trialFocused = true }
                .accessibilityLabel("Поле для пробной диктовки")

            if state.dictationState == .listening {
                Label("Слушаю…", systemImage: "waveform")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Идёт запись")
            }

            if trialSucceeded {
                Label("Готово — диктовка работает", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Пропустить пробу") { finishOnboarding() }
                    .buttonStyle(.link)
            }

            Spacer()
        }
    }

    // MARK: - Навигация

    private var nextButton: some View {
        Button(step.nextButtonTitle) {
            if step.isLast {
                finishOnboarding()
            } else {
                forward()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(blockReason != nil)
        .accessibilityHint(blockReason ?? "")
    }

    private var blockReason: String? {
        OnboardingGate.blockReason(
            step: step,
            microphoneGranted: state.microphoneGranted,
            accessibilityGranted: state.accessibilityGranted,
            modelState: state.modelState,
            engineReady: state.isEngineReady,
            trialSucceeded: trialSucceeded
        )
    }

    private var trialSucceeded: Bool {
        state.successfulDictationCount > trialStartCount
            && !trial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func forward() {
        guard let next = step.next else { return }
        if next == .tryIt { trialStartCount = state.successfulDictationCount }
        withAnimation { step = next }
    }

    private func back() {
        guard let previous = step.previous else { return }
        withAnimation { step = previous }
    }

    private func finishOnboarding() {
        onFinish()
        // Окно закрывается здесь же. Иначе на экране оставалась бы пустая
        // рамка после завершения настройки.
        dismiss()
    }
}

private struct OnboardingPermission: View {
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: status.granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status.granted ? .green : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Название, пояснение и галочка — про одно и то же. По отдельности
            // VoiceOver читает их тремя элементами, и «выдано» повисает без
            // хозяина.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityValue(status.accessibilityValue)

            Spacer()

            if let title = status.actionTitle {
                Button(title, action: action)
                    .accessibilityLabel(status.actionAccessibilityLabel ?? title)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
