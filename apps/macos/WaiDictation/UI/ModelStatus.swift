import Foundation
import LocalASR

/// Что человек видит про модель — в любом её состоянии и на обоих экранах.
///
/// Один тип на онбординг и настройки намеренно: раньше эти шесть состояний были
/// расписаны в двух местах разными словами, и любое изменение приходилось
/// вносить дважды. Второе место рано или поздно отставало.
struct ModelStatus: Equatable {
    enum Tone: Equatable {
        case neutral
        case success
        case failure
    }

    enum Action: Hashable {
        case install
        case retry
        case repair
        case cancel
        case delete

        /// Кнопка называет настоящий объём: полный для чистой установки и
        /// только остаток — когда после обновления доскачивается подсказчик.
        func title(downloadMegabytes: Int) -> String {
            switch self {
            case .install: return "Скачать модель — \(downloadMegabytes) МБ"
            case .retry: return "Попробовать снова"
            case .repair: return "Скачать модель заново — \(downloadMegabytes) МБ"
            case .cancel: return "Отменить загрузку"
            case .delete: return "Удалить модель"
            }
        }

        /// Подсказка для VoiceOver: что случится по нажатию.
        func hint(downloadMegabytes: Int) -> String {
            switch self {
            case .install: return "Скачает около \(downloadMegabytes) МБ. Это единственная загрузка приложения."
            case .retry: return "Повторит загрузку модели с начала."
            case .repair: return "Скачает и проверит новую копию модели. Повреждённая копия не используется."
            case .cancel: return "Остановит загрузку и удалит недокачанные файлы."
            case .delete: return "Освободит место на диске. Диктовка перестанет работать, пока модель не скачана заново."
            }
        }
    }

    /// Где показывается — от этого зависит только набор кнопок.
    enum Place {
        case onboarding
        case settings
    }

    var title: String
    var detail: String?
    /// Доля выполнения, если она осмысленна.
    var progress: Double?
    /// Подпись к индикатору — она же значение для VoiceOver.
    var progressLabel: String?
    var actions: [Action]
    var tone: Tone
    /// Что объявить VoiceOver при смене состояния.
    var announcement: String
    /// Сколько скачает кнопка install/repair — полный объём или остаток.
    var downloadMegabytes: Int = 586

    func title(for action: Action) -> String {
        action.title(downloadMegabytes: downloadMegabytes)
    }

    func hint(for action: Action) -> String {
        action.hint(downloadMegabytes: downloadMegabytes)
    }

    static func make(
        state: ModelState,
        isPreparingEngine: Bool,
        place: Place,
        downloadMegabytes: Int = 586
    ) -> ModelStatus {
        var status = makeStatus(state: state, isPreparingEngine: isPreparingEngine, place: place, downloadMegabytes: downloadMegabytes)
        status.downloadMegabytes = downloadMegabytes
        return status
    }

    private static func makeStatus(
        state: ModelState,
        isPreparingEngine: Bool,
        place: Place,
        downloadMegabytes: Int
    ) -> ModelStatus {
        switch state {
        case .notInstalled:
            return ModelStatus(
                title: "Модель не установлена",
                detail: "\(downloadMegabytes) МБ с Hugging Face CDN; при недоступности — зеркало GitHub. После проверки распознавание работает без сети.",
                progress: nil,
                progressLabel: nil,
                actions: [.install],
                tone: .neutral,
                announcement: "Модель не установлена"
            )

        case let .downloading(received, total):
            let label = "\(megabytes(received)) из \(megabytes(total)) МБ"
            return ModelStatus(
                title: "Скачиваю модель…",
                detail: "Можно продолжать — загрузка не прервётся.",
                progress: state.progress,
                progressLabel: label,
                actions: [.cancel],
                tone: .neutral,
                announcement: "Скачиваю модель, \(label)"
            )

        case let .verifying(checked, total):
            let label = "Файл \(checked) из \(total)"
            return ModelStatus(
                title: "Проверяю скачанное…",
                detail: "Сверяю контрольные суммы всех файлов.",
                progress: state.progress,
                progressLabel: label,
                actions: [],
                tone: .neutral,
                announcement: "Проверяю скачанное, \(label)"
            )

        case .ready:
            return ModelStatus(
                title: "Модель готова",
                // Пока идёт первая загрузка в нейромодуль, человек видит
                // «готова», но диктовка ещё подумает. Молчать об этом — значит
                // получить жалобу на медленный первый раз.
                detail: isPreparingEngine
                    ? "Готовлю к первому запуску — это занимает несколько секунд и только один раз."
                    : nil,
                progress: nil,
                progressLabel: nil,
                actions: place == .settings ? [.delete] : [],
                tone: .success,
                announcement: isPreparingEngine ? "Модель готова, готовлю к первому запуску" : "Модель готова"
            )

        case let .repairRequired(detail):
            let reason = message(for: .repairRequired(detail))
            return ModelStatus(
                title: "Модель требует восстановления",
                detail: reason,
                progress: nil,
                progressLabel: nil,
                actions: [.repair],
                tone: .failure,
                announcement: "Модель требует восстановления. \(reason)"
            )

        case let .failed(error):
            let reason = message(for: error)
            let requiresRepair: Bool
            if case .repairRequired = error {
                requiresRepair = true
            } else {
                requiresRepair = false
            }
            return ModelStatus(
                title: requiresRepair ? "Модель требует восстановления" : "Не удалось установить модель",
                detail: reason,
                progress: nil,
                progressLabel: nil,
                actions: [requiresRepair ? .repair : .retry],
                tone: .failure,
                announcement: requiresRepair
                    ? "Модель требует восстановления. \(reason)"
                    : "Не удалось установить модель. \(reason)"
            )

        case .deleting:
            return ModelStatus(
                title: "Удаляю модель…",
                detail: nil,
                progress: nil,
                progressLabel: nil,
                actions: [],
                tone: .neutral,
                announcement: "Удаляю модель"
            )
        }
    }

    /// Ошибка человеческими словами.
    ///
    /// Раньше сюда печаталось `String(describing:)` — то есть человек видел
    /// `notEnoughDiskSpace(requiredBytes: 594000000, availableBytes: 1200000)`
    /// и должен был сам догадаться, что на диске нет места.
    static func message(for error: ModelStoreError) -> String {
        switch error {
        case let .notEnoughDiskSpace(required, available):
            return """
                На диске не хватает места: нужно \(megabytes(required)) МБ, \
                свободно \(megabytes(available)) МБ.
                """
        case let .download(detail):
            return "Не удалось скачать: \(detail)"
        case let .verification(detail):
            return "Скачанное не сошлось с контрольными суммами: \(detail)"
        case let .install(detail):
            return "Не удалось разложить файлы: \(detail)"
        case let .repairRequired(detail):
            return "Модель повреждена или неполна: \(detail). Скачайте её заново по явной команде."
        case let .manifest(detail):
            return "Испорчен список файлов модели: \(detail)"
        case let .importSource(detail):
            return "Папка не подошла: \(detail)"
        case .cancelled:
            return "Загрузка отменена."
        }
    }

    /// Байты в мегабайты — так, как их считает Finder.
    private static func megabytes(_ bytes: Int64) -> Int {
        Int(bytes / 1_000_000)
    }
}
