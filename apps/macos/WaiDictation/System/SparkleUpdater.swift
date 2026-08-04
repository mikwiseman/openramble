import AppKit
import Foundation
import Sparkle

/// Обновления приложения.
///
/// Sparkle — второе и последнее место в продукте, которое умеет ходить в сеть.
/// Поэтому здесь всё устроено так, чтобы она молчала, пока её не попросят.
///
/// Настройки, без которых обещание «сеть только по вашей команде» было бы
/// неправдой, лежат в Info.plist (см. `apps/macos/project.yml`):
///
/// - `SUEnableAutomaticChecks = false` — самый важный. Это не «мы не включали
///   автопроверку», а «мы ответили за пользователя нет». Без этого ключа
///   Sparkle на втором запуске сам показывает окно «проверять обновления?»
///   и по умолчанию включает проверки — то есть приложение пошло бы в сеть
///   само, без спроса, в первые секунды работы.
/// - `SUSendProfileInfo = false` — вместе с запросом не уходит отчёт о железе,
///   версии системы и языке.
/// - `SUAllowsAutomaticUpdates = false` — фоновой загрузки и установки нет
///   даже как опции: обновление ставится только по нажатию.
///
/// Включить проверку по расписанию можно в настройках — и это единственный
/// выключатель, который меняет сетевое поведение приложения.
@MainActor
public final class SparkleUpdater: ObservableObject {
    /// Можно ли прямо сейчас запустить проверку. Пока идёт другая проверка или
    /// установка — нельзя, и пункт меню должен быть выключен.
    @Published public private(set) var canCheckForUpdates = false

    /// Sparkle не запустился. Такое бывает при неверной настройке подписи
    /// обновлений, и молчать об этом нельзя: человек будет думать, что
    /// обновления приходят, а их нет.
    @Published public private(set) var startupFailure: String?

    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    public init() {
        // Запускаем механизм сами, а не через `startingUpdater: true`. Там
        // ошибка настройки превращается в модальное окно Sparkle, которое у
        // приложения из строки меню появляется буквально ниоткуда. Нам нужна
        // та же ошибка, но в настройках и своими словами.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            // Sparkle меняет это свойство только на главном потоке.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }

        // Ключ проверяем сами, до запуска.
        //
        // Собственная проверка Sparkle здесь дырявая: при HTTPS-адресе фида и
        // подписанном приложении она пропускает отсутствие ключа EdDSA, пишет
        // предупреждение в лог и запускается — дальше обновления проверяются
        // одной лишь подписью кода (`SPUUpdater.m`, ветка `!hasAnyPublicKey`).
        // Это ровно тот случай, который у нас и будет на релизе, и ошибки при
        // нём не возникает. Обещание «обновления подписаны нашим ключом» тихо
        // ослабло бы, а узнать об этом было бы неоткуда.
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let publicKey, !publicKey.isEmpty else {
            startupFailure = """
                This build has no public update-signing key (SUPublicEDKey). \
                Updates are disabled: without it there is no way to verify them.
                """
            return
        }

        do {
            // `start()` — это `-[SPUUpdater startUpdater:]`, Swift срезает
            // с имени метода название типа. Запуск ничего не скачивает:
            // расписание проверок включается, только если пользователь сам
            // разрешил автопроверку.
            try controller.updater.start()
        } catch {
            startupFailure = error.localizedDescription
        }
    }

    /// Проверять обновления по расписанию (примерно раз в сутки).
    ///
    /// Значение хранит сам Sparkle в настройках приложения. Своей копии тут
    /// заводить нельзя: две правды об одном выключателе рано или поздно
    /// разойдутся, и приложение начнёт ходить в сеть вопреки галочке.
    public var automaticChecksEnabled: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            guard newValue != controller.updater.automaticallyChecksForUpdates else { return }
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Проверить обновления прямо сейчас — по команде пользователя.
    public func checkForUpdates() {
        // Приложение живёт в строке меню и не бывает активным. Без этого окно
        // Sparkle открылось бы позади чужих окон, и человек решил бы, что
        // ничего не произошло.
        NSApplication.shared.activate()
        controller.updater.checkForUpdates()
    }
}
