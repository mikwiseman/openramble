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
                        Button("Back") { back() }
                            .accessibilityHint("Go back to step \(step.rawValue)")
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
            "Repair Accessibility access?",
            isPresented: $showAccessibilityRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Wai Dictation's access and relaunch", role: .destructive) {
                state.repairAccessibility()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will remove only Wai Dictation's Accessibility entries. After the relaunch you will need to grant access again.")
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
            Text("Dictation that never sends your speech anywhere")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Press a key, speak, release — the text appears where your cursor was. In any app.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Speech is recognized by a model on your disk. Works on a plane.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "airplane").foregroundStyle(.blue)
                }
                Label {
                    Text("The app goes online only on your command: to download the model and, if you turn it on, to check for updates.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                }
                Label {
                    Text("No accounts, no analytics, no reports. The code is open — you can check.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.open").foregroundStyle(.blue)
                }
                Label {
                    Text("Safe beta requires a Mac with Apple Silicon and macOS 14 or later.")
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
            Text("Two permissions")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Both are granted in System Settings. We'll show you exactly where.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                OnboardingPermission(
                    status: PermissionStatus(
                        title: "Microphone",
                        detail: "To hear your speech.",
                        granted: state.microphoneGranted
                    ),
                    action: state.requestMicrophone
                )
                OnboardingPermission(
                    status: PermissionStatus.accessibility(
                        state: state.accessibilityState,
                        detail: "To hear the hotkey and insert the finished text.",
                    ),
                    action: performAccessibilityAction
                )
            }

            if needsAccessibilityRepair {
                HStack {
                    Button("Show the app in Finder") {
                        state.revealApplicationForAccessibility()
                    }
                    Button("Open System Settings") {
                        state.openAccessibilitySettings()
                    }
                }
                .font(.caption)
            }

            Text("A separate “Input Monitoring” permission is not needed. The app doesn't store or transmit keystrokes — it only looks for your hotkey.")
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
            Text("Recognition model")
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
            Text("Try it")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Picker("Hotkey", selection: $state.hotkey) {
                ForEach(DictationHotkey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("The key you hold down while dictating")

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
                .accessibilityLabel("Key warning. \(warning)")
            }

            Text("Hold \(state.hotkey.title), say something, and release. The text will appear in the field below.")
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
                .accessibilityLabel("Trial dictation field")

            if state.dictationState == .listening {
                Label("Listening…", systemImage: "waveform")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Recording")
            }

            if trialSucceeded {
                Label("Done — dictation works", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Skip the try-out") { finishOnboarding() }
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
