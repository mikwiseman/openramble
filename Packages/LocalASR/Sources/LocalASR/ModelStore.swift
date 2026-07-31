import DictationCore
import Foundation

/// Состояние установки модели.
public enum ModelState: Sendable, Equatable {
    case notInstalled
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case verifying(checked: Int, total: Int)
    case ready(directory: URL)
    case failed(ModelStoreError)
    case deleting

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Доля выполнения для индикатора, если она осмысленна.
    public var progress: Double? {
        switch self {
        case let .downloading(received, total) where total > 0:
            return min(1, Double(received) / Double(total))
        case let .verifying(checked, total) where total > 0:
            return Double(checked) / Double(total)
        default:
            return nil
        }
    }
}

public enum ModelStoreError: Error, Sendable, Equatable {
    case manifest(String)
    case download(String)
    case verification(String)
    case install(String)
    /// Папка, из которой пользователь просил взять модель, не подходит.
    case importSource(String)
    case notEnoughDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case cancelled
}

/// Установка, проверка и удаление модели.
///
/// Актор, потому что установка, удаление и чтение состояния не должны
/// пересекаться. Порядок жёсткий: скачать в staging → проверить там же →
/// перенести одним движением → записать метку готовности. Промежуточное
/// состояние никогда не выглядит как рабочая установка.
public actor ModelStore {
    private let manifest: ModelManifest
    private let layout: ModelInstallLayout
    private let downloader: ModelDownloading
    private let verifier: ModelVerifier
    private let fileManager: FileManager

    private var state: ModelState = .notInstalled
    private var observers: [UUID: AsyncStream<ModelState>.Continuation] = [:]
    private var activeTask: Task<Void, Never>?

    public init(
        manifest: ModelManifest,
        layout: ModelInstallLayout,
        downloader: ModelDownloading = URLSessionModelDownloader(),
        verifier: ModelVerifier = ModelVerifier(),
        fileManager: FileManager = .default
    ) {
        self.manifest = manifest
        self.layout = layout
        self.downloader = downloader
        self.verifier = verifier
        self.fileManager = fileManager
    }

    // MARK: - Наблюдение

    public func currentState() -> ModelState { state }

    /// Поток состояний для интерфейса. Первым приходит текущее значение.
    public func states() -> AsyncStream<ModelState> {
        AsyncStream { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func setState(_ newState: ModelState) {
        state = newState
        for continuation in observers.values {
            continuation.yield(newState)
        }
    }

    // MARK: - Проверка того, что уже установлено

    /// Осмотреть диск и обновить состояние.
    ///
    /// Установка считается готовой только при валидной метке, совпадающей с
    /// текущим манифестом. Всё остальное — «не установлено», даже если файлы
    /// частично на месте.
    @discardableResult
    public func refreshState() -> ModelState {
        sweepStaleStaging()

        guard let data = try? LocalFile.read(layout.readyMarker),
              let marker = try? JSONDecoder().decode(ModelReadyMarker.self, from: data),
              marker.matches(manifest)
        else {
            setState(.notInstalled)
            return state
        }

        setState(.ready(directory: layout.installedDirectory))
        return state
    }

    /// Убрать брошенные staging-директории от прерванных попыток.
    ///
    /// Пока установка идёт, не трогаем ничего: осмотр диска вызывается из
    /// интерфейса и легко приходится на середину закачки — иначе он сносил бы
    /// папку, в которую как раз пишет установка, и та падала бы посреди дела.
    private func sweepStaleStaging() {
        guard activeTask == nil else { return }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: layout.modelDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: - Установка

    /// Скачать и установить модель. Повторный вызов во время работы игнорируется.
    public func install() async {
        guard activeTask == nil else { return }
        if case .ready = state { return }

        let task = Task { await performInstall() }
        activeTask = task
        await task.value
        activeTask = nil
    }

    /// Отменить установку. Скачанное в staging удаляется — недоверенных остатков не держим.
    public func cancelInstall() {
        activeTask?.cancel()
    }

    /// Взять модель из готовой папки, не заходя в сеть.
    ///
    /// Второй независимый путь к модели: человек скачал её на другой машине или
    /// получил от коллеги. Проверка ровно та же, что и после загрузки, — все
    /// суммы SHA-256 из манифеста, — поэтому доверия к папке не требуется.
    ///
    /// Ожидается папка, в которой пути из манифеста лежат прямо: `Encoder.mlmodelc/…`,
    /// `parakeet_vocab.json` и так далее. Это та самая папка, которую отдаёт
    /// `ModelInstallLayout.engineDirectory` на машине, где модель уже стоит.
    public func importModel(from directory: URL) async {
        guard activeTask == nil else { return }
        if case .ready = state { return }

        let task = Task { await performImport(from: directory) }
        activeTask = task
        await task.value
        activeTask = nil
    }

    private func performInstall() async {
        await runInstall { staging in
            try await self.downloadAll(into: staging)
        }
    }

    private func performImport(from source: URL) async {
        await runInstall { staging in
            try self.copyAll(from: source, into: staging)
        }
    }

    /// Общий скелет установки: собрать в staging, проверить, переехать.
    ///
    /// Загрузка и импорт отличаются только тем, откуда берутся файлы. Всё
    /// остальное — проверка сумм, атомарный переезд, уборка за собой на любой
    /// ошибке — обязано совпадать, иначе один из путей рано или поздно окажется
    /// слабее другого.
    private func runInstall(collect: (URL) async throws -> Void) async {
        let attempt = UUID()
        let staging = layout.stagingDirectory(attempt: attempt)

        do {
            try preflightDiskSpace()
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }

            try await collect(staging)
            try Task.checkCancellation()
            try verifyAll(inside: staging)
            try Task.checkCancellation()
            try promote(from: staging)

            excludeFromBackup(layout.modelDirectory)
            setState(.ready(directory: layout.installedDirectory))
        } catch is CancellationError {
            try? fileManager.removeItem(at: staging)
            setState(.notInstalled)
        } catch let error as ModelStoreError {
            try? fileManager.removeItem(at: staging)
            setState(.failed(error))
        } catch {
            try? fileManager.removeItem(at: staging)
            setState(.failed(.install(error.localizedDescription)))
        }
    }

    /// Скопировать файлы манифеста из чужой папки в staging.
    ///
    /// Копируем, а не переносим: папка чужая, забирать из неё файлы нельзя.
    private func copyAll(from source: URL, into staging: URL) throws {
        let total = manifest.totalByteCount
        var completed: Int64 = 0
        setState(.downloading(receivedBytes: 0, totalBytes: total))

        for file in manifest.files {
            try Task.checkCancellation()

            // Барьер путей — тот же самый и такой же строгий: файл, пришедший
            // снаружи, доверия не имеет ничуть не больше скачанного. Проверяются
            // обе стороны: и откуда берём, и куда кладём.
            let origin: URL
            let destination: URL
            do {
                origin = try layout.destination(for: file, inside: source)
                destination = try layout.destination(
                    for: file,
                    inside: layout.engineDirectory(inside: staging)
                )
            } catch {
                throw ModelStoreError.importSource("путь \(file.path) ведёт за пределы папки")
            }
            try checkImportable(origin, path: file.path)

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try fileManager.copyItem(at: origin, to: destination)
            } catch {
                throw ModelStoreError.importSource("не скопировался \(file.path): \(error.localizedDescription)")
            }

            completed += file.byteCount
            setState(.downloading(receivedBytes: completed, totalBytes: total))
        }
    }

    /// Годится ли файл из чужой папки к копированию.
    ///
    /// Символическая ссылка отвергается отдельно: её содержимое можно подменить
    /// после проверки суммы, и в установленной модели остался бы указатель
    /// наружу вместо файла.
    private func checkImportable(_ url: URL, path: String) throws {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard let values else {
            throw ModelStoreError.importSource("в папке нет файла \(path)")
        }
        if values.isSymbolicLink == true {
            throw ModelStoreError.importSource("\(path) — символическая ссылка, а нужен файл")
        }
        guard values.isRegularFile == true else {
            throw ModelStoreError.importSource("\(path) — не обычный файл")
        }
    }

    /// Убедиться, что места хватит: файлы сначала лежат в staging, потом переезжают,
    /// поэтому пикового запаса нужно чуть больше самой модели.
    private func preflightDiskSpace() throws {
        let required = Int64(Double(manifest.totalByteCount) * 1.2)
        let values = try? layout.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }

        guard available > required else {
            throw ModelStoreError.notEnoughDiskSpace(
                requiredBytes: required,
                availableBytes: Int64(available)
            )
        }
    }

    private func downloadAll(into staging: URL) async throws {
        let total = manifest.totalByteCount
        var completed: Int64 = 0
        setState(.downloading(receivedBytes: 0, totalBytes: total))

        for file in manifest.files {
            try Task.checkCancellation()

            let sources = manifest.downloadURLs(for: file)
            guard !sources.isEmpty else {
                throw ModelStoreError.manifest("не построился адрес для \(file.path)")
            }
            let destination = try layout.destination(for: file, inside: layout.engineDirectory(inside: staging))
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let alreadyDone = completed
            let temporary = try await downloadFromAnySource(
                sources,
                file: file,
                alreadyDone: alreadyDone,
                total: total
            )

            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
            completed += file.byteCount
            setState(.downloading(receivedBytes: completed, totalBytes: total))
        }
    }

    /// Пройти по адресам сверху вниз, пока файл не скачается.
    ///
    /// Отказ источника и отказ пользователя — разные вещи. Нет файла, нет
    /// доступа, нет хоста — повод взять следующий адрес. Отмена — повод
    /// остановиться совсем: перебирать зеркала после нажатия «отмена» значит
    /// продолжать качать 483 МБ вопреки прямой команде.
    private func downloadFromAnySource(
        _ sources: [URL],
        file: ModelManifest.File,
        alreadyDone: Int64,
        total: Int64
    ) async throws -> URL {
        var failures: [String] = []

        for (index, url) in sources.enumerated() {
            do {
                return try await downloader.download(
                    from: url,
                    expectedBytes: file.byteCount,
                    onProgress: { [weak self] received in
                        Task { [weak self] in
                            await self?.reportDownloadProgress(alreadyDone + received, total: total)
                        }
                    }
                )
            } catch ModelDownloadError.cancelled {
                throw CancellationError()
            } catch let error as ModelDownloadError {
                failures.append("\(url.host() ?? url.absoluteString): \(error)")
                // Прогресс мог уйти вперёд на неудачной попытке — возвращаем
                // его назад, иначе индикатор поедет и обгонит сам себя.
                reportDownloadProgress(alreadyDone, total: total)
                if index == sources.count - 1 {
                    throw ModelStoreError.download("\(file.path): \(failures.joined(separator: "; "))")
                }
            }
        }

        throw ModelStoreError.download("\(file.path): не осталось источников")
    }

    private func reportDownloadProgress(_ received: Int64, total: Int64) {
        guard case .downloading = state else { return }
        setState(.downloading(receivedBytes: received, totalBytes: total))
    }

    private func verifyAll(inside staging: URL) throws {
        setState(.verifying(checked: 0, total: manifest.files.count))
        do {
            for (index, file) in manifest.files.enumerated() {
                try Task.checkCancellation()
                let destination = try layout.destination(for: file, inside: layout.engineDirectory(inside: staging))
                try verifier.verify(file: file, at: destination)
                setState(.verifying(checked: index + 1, total: manifest.files.count))
            }
        } catch let failure as ModelVerifier.Failure {
            throw ModelStoreError.verification(String(describing: failure))
        }
    }

    /// Переезд staging → финальная директория одним движением, затем метка готовности.
    private func promote(from staging: URL) throws {
        let destination = layout.installedDirectory
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)

            let marker = ModelReadyMarker(manifest: manifest, verifiedAt: Date())
            let data = try JSONEncoder().encode(marker)
            try data.write(to: layout.readyMarker, options: .atomic)
        } catch {
            throw ModelStoreError.install(error.localizedDescription)
        }
    }

    /// Модель — скачиваемый кэш, в резервных копиях ей не место.
    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    // MARK: - Удаление

    /// Удалить установленную модель.
    ///
    /// Если в этот момент идёт закачка, сначала останавливаем её и дожидаемся
    /// конца. Иначе удаление снесло бы папку из-под живой установки: та
    /// продолжила бы писать в никуда и закончилась бы невнятной ошибкой вместо
    /// понятного «модель удалена».
    public func delete() async {
        if let activeTask {
            activeTask.cancel()
            await activeTask.value
        }

        setState(.deleting)
        try? fileManager.removeItem(at: layout.modelDirectory)
        setState(.notInstalled)
    }
}
