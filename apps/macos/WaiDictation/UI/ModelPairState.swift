import Foundation
import LocalASR

/// Объединение состояний двух моделей в одно, которое видит человек.
///
/// Для человека распознавание и акустический подсказчик терминов — одна
/// «модель»: одна кнопка загрузки, один прогресс, одна судьба. Внутри это два
/// независимых хранилища со своими манифестами, и правило объединения — чистая
/// политика с тестами, а не логика во вью-модели.
enum ModelPairState {
    /// Порядок приоритетов: поломка громче всего, удаление и работа — дальше,
    /// готовность — только когда готовы обе.
    static func combine(
        main: ModelState,
        vocabulary: ModelState,
        mainTotalBytes: Int64,
        vocabularyTotalBytes: Int64,
        mainFileCount: Int,
        vocabularyFileCount: Int
    ) -> ModelState {
        let totalBytes = mainTotalBytes + vocabularyTotalBytes
        let totalFiles = mainFileCount + vocabularyFileCount

        if case let .failed(error) = main { return .failed(error) }
        if case let .failed(error) = vocabulary { return .failed(error) }

        if case let .repairRequired(detail) = main {
            return .repairRequired("recognition model: \(detail)")
        }
        if case let .repairRequired(detail) = vocabulary {
            return .repairRequired("vocabulary helper: \(detail)")
        }

        if case .deleting = main { return .deleting }
        if case .deleting = vocabulary { return .deleting }

        // Установка идёт последовательно: сначала основная, потом подсказчик.
        // Прогресс общий и не прыгает назад на границе между ними.
        if case let .downloading(received, _) = main {
            return .downloading(receivedBytes: received, totalBytes: totalBytes)
        }
        if case let .verifying(checked, _) = main {
            return .verifying(checked: checked, total: totalFiles)
        }
        if case let .downloading(received, _) = vocabulary {
            return .downloading(receivedBytes: mainTotalBytes + received, totalBytes: totalBytes)
        }
        if case let .verifying(checked, _) = vocabulary {
            return .verifying(checked: mainFileCount + checked, total: totalFiles)
        }

        if case let .ready(directory) = main, case .ready = vocabulary {
            return .ready(directory: directory)
        }

        return .notInstalled
    }

    /// Сколько байт осталось скачать: полный объём для чистой установки,
    /// только остаток — для добора после обновления приложения.
    static func remainingBytes(
        main: ModelState,
        vocabulary: ModelState,
        mainTotalBytes: Int64,
        vocabularyTotalBytes: Int64
    ) -> Int64 {
        var bytes: Int64 = 0
        if !main.isReady { bytes += mainTotalBytes }
        if !vocabulary.isReady { bytes += vocabularyTotalBytes }
        return bytes
    }
}
