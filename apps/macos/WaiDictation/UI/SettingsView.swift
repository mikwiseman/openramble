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
                .accessibilityHint("Клавиша, которую надо удерживать во время диктовки")

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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Предупреждение о клавише. \(warning)")
                }
            }

            Section {
                Toggle("Звук начала и конца записи", isOn: $state.soundsEnabled)
                    .accessibilityHint("Короткий сигнал, когда запись началась и когда закончилась")
            }

            Section("Обновления") {
                Toggle("Проверять обновления автоматически", isOn: $updater.automaticChecksEnabled)
                    .accessibilityHint("Единственный выключатель, который меняет сетевое поведение приложения")
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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Обновления не работают. \(failure)")
                }
            }

            Section("Разрешения") {
                PermissionRow(
                    status: PermissionStatus(
                        title: "Универсальный доступ",
                        detail: "Нужен, чтобы услышать горячую клавишу и вставить текст.",
                        granted: state.accessibilityGranted
                    ),
                    action: state.requestAccessibility
                )
                PermissionRow(
                    status: PermissionStatus(
                        title: "Микрофон",
                        detail: "Нужен, чтобы записать вашу речь.",
                        granted: state.microphoneGranted
                    ),
                    action: state.requestMicrophone
                )
            }
        }
        .formStyle(.grouped)
        // Разрешения выдаются в системных настройках, и вернувшийся сюда
        // человек должен увидеть свежее состояние, а не то, что было до ухода.
        .task { state.refreshPermissions() }
    }
}

private struct PermissionRow: View {
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityValue(status.accessibilityValue)

            Spacer()
            if let title = status.actionTitle {
                Button(title, action: action)
                    .accessibilityLabel(status.actionAccessibilityLabel ?? title)
            } else {
                Label("Выдан", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    // Галочка уже прочитана как значение строки: второй раз
                    // «выдан» без хозяина только мешает.
                    .accessibilityHidden(true)
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
                ModelStatusView(
                    status: ModelStatus.make(
                        state: state.modelState,
                        isPreparingEngine: state.isPreparingEngine,
                        place: .settings
                    ),
                    install: state.installModel,
                    delete: state.deleteModel
                )
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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Словарь не изменяется. \(problem.message)")
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
                        // Без имени это просто «добавить сорок два».
                        .accessibilityLabel("Добавить \(state.availableStarterCount) готовых замен для английских терминов")
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
                    // Строка читается целиком: «сентри», стрелка и «Sentry»
                    // по отдельности не значат ничего.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Слышится как «\(replacement.spoken)», писать как «\(replacement.written)»")
                }
                .onDelete(perform: state.removeReplacements)
            }
            .disabled(!state.isDictionaryEditable)
            .accessibilityLabel("Список замен")

            HStack {
                // Подпись у полей только в виде подсказки внутри рамки: пустое
                // поле VoiceOver прочитает, а заполненное — уже нет, и человек
                // потеряет, в каком из двух полей он стоит.
                TextField("Слышится как", text: $spoken)
                    .accessibilityLabel("Слышится как")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("Писать как", text: $written)
                    .accessibilityLabel("Писать как")
                Button("Добавить") {
                    state.addReplacement(spoken: spoken, written: written)
                    spoken = ""
                    written = ""
                }
                .disabled(spoken.isEmpty || written.isEmpty || !state.isDictionaryEditable)
                .accessibilityLabel("Добавить замену")
                .accessibilityHint(
                    state.isDictionaryEditable
                        ? "Заполните оба поля"
                        : "Словарь не изменяется, пока прежние данные не прочитались"
                )
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
                .accessibilityAddTraits(.isHeader)
            Text("Диктовка, которая работает целиком на вашем Mac.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Что уходит в сеть")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Загрузка модели по вашей команде и проверка обновлений, если вы её включили. Больше ничего: речь, текст и нажатия клавиш никуда не отправляются и нигде не сохраняются, кроме вашего компьютера.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Модель распознавания")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
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
