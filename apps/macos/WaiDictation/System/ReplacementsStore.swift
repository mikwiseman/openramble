import DictationCore
import Foundation

/// Хранение пользовательского словаря замен.
///
/// Словарь — единственное, что человек набирает в этом приложении руками, и
/// единственная накопленная в нём ценность. Поэтому правило здесь одно:
/// **не смог прочитать — не пишу.**
///
/// Подставить вместо непрочитанного пустой массив (как делалось раньше) значит
/// при первой же правке перезаписать им ключ. Словарь исчезает целиком, молча и
/// необратимо, а выглядит это как «настройки сбросились сами».
public struct ReplacementsStore {
    /// Номер формата хранения.
    ///
    /// Нужен ради отката. Открытый код откатывают на версию назад регулярно, и
    /// старое приложение обязано увидеть «это записано чем-то новее» и не
    /// тронуть — иначе откат на день уничтожает словарь, накопленный за месяц.
    static let currentVersion = 1

    /// Почему словарь заблокирован на запись.
    public enum Problem: Sendable, Equatable {
        /// Ключ есть, но разобрать не вышло. Исходные данные отложены в сторону.
        case unreadable(quarantineKey: String)
        /// Записано более новой версией приложения.
        case writtenByNewerVersion(Int)

        public var message: String {
            switch self {
            case .unreadable:
                return """
                    The replacement dictionary couldn't be read, so it can't be edited. \
                    The previous data is preserved — nothing is lost.
                    """
            case let .writtenByNewerVersion(version):
                return """
                    The replacement dictionary was written by a newer version of the app \
                    (format \(version)). It can't be edited so that version's data isn't lost.
                    """
            }
        }
    }

    struct Load: Equatable {
        var replacements: [DictionaryReplacement]
        /// Не nil — записывать нельзя.
        var problem: Problem?
    }

    /// Хранимое. Массив завёрнут в объект только ради номера версии.
    private struct Envelope: Codable {
        let version: Int
        let items: [DictionaryReplacement]
    }

    /// Только номер версии, без содержимого.
    ///
    /// Читается отдельно и первым. Разбирать версию вместе с элементами нельзя:
    /// откат ловит ровно тот случай, когда элементы записаны в незнакомой форме,
    /// и разбор об них спотыкается. Тогда «это чужая версия, не трогать»
    /// превратилось бы в «не прочитал» — и данные новой версии пошли бы под нож.
    private struct VersionProbe: Codable {
        let version: Int
    }

    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date

    init(defaults: UserDefaults, key: String, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.key = key
        self.now = now
    }

    func load() -> Load {
        guard let data = defaults.data(forKey: key) else {
            // Ключа нет — обычный первый запуск, словарь пуст. Это не авария.
            return Load(replacements: [], problem: nil)
        }

        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) {
            guard probe.version >= 1 else {
                return Load(replacements: [], problem: .unreadable(quarantineKey: quarantine(data)))
            }
            guard probe.version <= Self.currentVersion else {
                // Ничего не откладываем и ничего не трогаем: данные целы, просто
                // не наши. Вернётся новая версия — прочитает их сама.
                return Load(replacements: [], problem: .writtenByNewerVersion(probe.version))
            }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                // Версия наша, а содержимое не разобралось. Прочитать половину и
                // записать её обратно значит потерять вторую.
                return Load(replacements: [], problem: .unreadable(quarantineKey: quarantine(data)))
            }
            return Load(replacements: envelope.items, problem: nil)
        }

        // Старый формат: голый массив без номера версии. Читаем как есть, а в
        // новый он переедет при первой же записи.
        if let legacy = try? JSONDecoder().decode([DictionaryReplacement].self, from: data) {
            return Load(replacements: legacy, problem: nil)
        }

        return Load(replacements: [], problem: .unreadable(quarantineKey: quarantine(data)))
    }

    func save(_ replacements: [DictionaryReplacement]) throws {
        let data = try JSONEncoder().encode(
            Envelope(version: Self.currentVersion, items: replacements)
        )
        defaults.set(data, forKey: key)
    }

    /// Отложить непрочитанное в сторону.
    ///
    /// Пишем в НОВЫЙ ключ, исходный не трогаем: карантин обязан быть добавлением,
    /// а не перемещением, иначе спасательная операция сама и теряет данные.
    private func quarantine(_ data: Data) -> String {
        let formatter = ISO8601DateFormatter()
        let quarantineKey = "\(key).unreadable.\(formatter.string(from: now()))"
        defaults.set(data, forKey: quarantineKey)
        return quarantineKey
    }
}
