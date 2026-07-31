import Foundation

/// Складывает текст, который не удалось вставить.
///
/// Это последняя страховка: распознанное нельзя терять из-за того, что
/// приложение-получатель оказалось недоступно.
///
/// Живёт в ядре, а не в приложении, намеренно: здесь нет ни AppKit, ни системных
/// разрешений — только файлы, — зато есть правила, на которые пользователь
/// полагается, не имея возможности их проверить. Такие правила должны быть
/// покрыты тестами.
public struct RecoveryStore: RecoveryStoring {
    private let directory: URL
    /// Сколько файлов держать. Приватный продукт не должен копить бессрочный
    /// архив всего, что было сказано.
    private let keepLast = 20
    private let maximumAge: TimeInterval = 7 * 24 * 3600

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ text: String) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: fileName(at: Date()), directoryHint: .notDirectory)
        try Data(text.utf8).write(to: url, options: .atomic)

        prune()
        return url
    }

    /// Имя файла: отметка времени плюс случайный хвост.
    ///
    /// Хвост обязателен. Отметка времени идёт с точностью до секунды, а две
    /// неудачные вставки подряд укладываются в одну секунду легко — вторая
    /// молча затирала первую, и текст, ради спасения которого всё и затевалось,
    /// пропадал. Имя при этом ничего не говорит о содержимом: подсмотреть
    /// продиктованное по списку файлов нельзя.
    private func fileName(at date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let unique = String(UUID().uuidString.prefix(8))
        return "dictation-\(stamp)-\(unique).txt"
    }

    /// Убрать старые записи: и по возрасту, и по количеству.
    private func prune() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let now = Date()
        var survivors: [(url: URL, date: Date)] = []

        for entry in entries where entry.pathExtension == "txt" {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > maximumAge {
                try? FileManager.default.removeItem(at: entry)
            } else {
                survivors.append((entry, date))
            }
        }

        guard survivors.count > keepLast else { return }
        for item in survivors.sorted(by: { $0.date > $1.date }).dropFirst(keepLast) {
            try? FileManager.default.removeItem(at: item.url)
        }
    }
}
