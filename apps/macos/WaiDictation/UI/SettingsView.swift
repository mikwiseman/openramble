import DictationCore
import LocalASR
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettings(state: state, updater: state.updater)
                .tabItem { Label("Основное", systemImage: "gearshape") }
            ModelSettings(state: state)
                .tabItem { Label("Модель", systemImage: "waveform") }
            DictionarySettings(state: state)
                .tabItem { Label("Словарь", systemImage: "character.book.closed") }
            AboutView()
                .tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 400)
    }
}

// MARK: - Основное

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    // Sparkle сообщает о своих изменениях сам, через AppState они бы не дошли.
    @ObservedObject var updater: SparkleUpdater

    var body: some View {
        Form {
            Section {
                Picker("Горячая клавиша", selection: $state.hotkey) {
                    ForEach(DictationHotkey.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                    }
                }
                Text("Удерживайте клавишу и говорите. Двойное нажатие включает режим без удержания — тогда запись останавливается следующим нажатием.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = state.hotkeyWarning {
                    // Fn — единственная клавиша в списке, у которой есть своё
                    // системное назначение и которой может не быть на внешней
                    // клавиатуре. Молчать об этом значит оставить человека
                    // выяснять самому, почему диктовка «иногда не работает».
                    Label {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Toggle("Звук начала и конца записи", isOn: $state.soundsEnabled)
            }

            Section("Обновления") {
                Toggle("Проверять обновления автоматически", isOn: $updater.automaticChecksEnabled)
                Text("По умолчанию выключено. Если включить, приложение раз в сутки будет скачивать с GitHub маленький файл со списком версий. Это единственный выход в сеть, кроме загрузки модели: туда уходит ваш IP-адрес и номер версии, больше ничего — ни данных о компьютере, ни того, что вы диктовали.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Проверить сейчас", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                    Spacer()
                }

                if let failure = updater.startupFailure {
                    // Молчать нельзя: иначе человек будет считать, что
                    // обновления приходят, а они не приходят.
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Обновления не работают", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Разрешения") {
                PermissionRow(
                    title: "Универсальный доступ",
                    explanation: "Нужен, чтобы услышать горячую клавишу и вставить текст.",
                    granted: state.accessibilityGranted,
                    action: state.requestAccessibility
                )
                PermissionRow(
                    title: "Микрофон",
                    explanation: "Нужен, чтобы записать вашу речь.",
                    granted: state.microphoneGranted,
                    action: state.requestMicrophone
                )
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let explanation: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Выдан", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
                    .font(.title3)
            } else {
                Button("Выдать", action: action)
            }
        }
    }
}

// MARK: - Модель

private struct ModelSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                switch state.modelState {
                case .notInstalled:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Модель не установлена")
                        Text("Загрузка занимает около 483 МБ. После неё распознавание работает без интернета.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Скачать модель", action: state.installModel)
                    }

                case let .downloading(received, total):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Загрузка модели")
                        ProgressView(value: Double(received), total: Double(max(total, 1)))
                        Text("\(received / 1_000_000) из \(total / 1_000_000) МБ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case let .verifying(checked, total):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Проверка целостности")
                        ProgressView(value: Double(checked), total: Double(max(total, 1)))
                        Text("Файл \(checked) из \(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .ready:
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Модель готова", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if state.isPreparingEngine {
                            Text("Готовлю к первому запуску…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Удалить модель", role: .destructive, action: state.deleteModel)
                    }

                case let .failed(error):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Не удалось установить", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(String(describing: error))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Попробовать снова", action: state.installModel)
                    }

                case .deleting:
                    Text("Удаление…")
                }
            }

            Section {
                Text("Parakeet TDT 0.6B v3 — распознаёт 25 языков, включая русский и английский в одной фразе.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshModelState() }
    }
}

// MARK: - Словарь

private struct DictionarySettings: View {
    @ObservedObject var state: AppState
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Замены применяются к распознанному тексту. Полезно для названий, которые модель слышит иначе.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let problem = state.dictionaryProblem {
                    // Словарь заблокирован на запись. Сказать об этом обязаны
                    // здесь: человек стоит ровно на той странице, где собирается
                    // его править, и должен узнать до того, как начнёт.
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Словарь не изменяется", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                        Text(problem.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }

                if state.isDictionaryEditable, state.availableStarterCount > 0 {
                    HStack {
                        Text("Диктуете по-русски с английскими терминами? Модель пишет их кириллицей: «pull request» становится «пул реквест».")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Добавить \(state.availableStarterCount)") {
                            state.addStarterDictionary()
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()

            List {
                ForEach(state.replacements) { replacement in
                    HStack {
                        Text(replacement.spoken)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(replacement.written)
                    }
                }
                .onDelete(perform: state.removeReplacements)
            }
            .disabled(!state.isDictionaryEditable)

            HStack {
                TextField("Слышится как", text: $spoken)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                TextField("Писать как", text: $written)
                Button("Добавить") {
                    state.addReplacement(spoken: spoken, written: written)
                    spoken = ""
                    written = ""
                }
                .disabled(spoken.isEmpty || written.isEmpty || !state.isDictionaryEditable)
            }
            .padding()
        }
    }
}

// MARK: - О программе

private struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wai Dictation")
                .font(.title2.bold())
            Text("Диктовка, которая работает целиком на вашем Mac.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Что уходит в сеть")
                    .font(.headline)
                Text("Загрузка модели по вашей команде и проверка обновлений, если вы её включили. Больше ничего: речь, текст и нажатия клавиш никуда не отправляются и нигде не сохраняются, кроме вашего компьютера.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Модель распознавания")
                    .font(.headline)
                Text("Parakeet TDT 0.6B v3 © NVIDIA, лицензия CC BY 4.0. Конвертирована в Core ML и квантизована шестибитной палитрой проектом FluidInference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Библиотеки: FluidAudio (Apache 2.0), Sparkle (MIT).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
