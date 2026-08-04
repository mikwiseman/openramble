import DictationCore
import Foundation

/// Состояние установки модели.
public enum ModelState: Sendable, Equatable {
    case notInstalled
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case verifying(checked: Int, total: Int)
    case ready(directory: URL)
    case repairRequired(String)
    case failed(ModelStoreError)
    case deleting

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var requiresRepair: Bool {
        if case .repairRequired = self { return true }
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
    case repairRequired(String)
    /// Папка, из которой пользователь просил взять модель, не подходит.
    case importSource(String)
    case notEnoughDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case cancelled
}

/// Test seam для имитации process kill между файловыми шагами promotion.
public enum ModelPromotionCheckpoint: Sendable, Equatable, CaseIterable {
    case afterBackup
    case afterStagingMove
    case afterReadyMarker
    case afterBackupRemoval
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
    private let injectedPromotionFailure: ModelPromotionCheckpoint?

    private var state: ModelState = .notInstalled
    private var observers: [UUID: AsyncStream<ModelState>.Continuation] = [:]
    private var activeTask: Task<Void, Never>?

    public init(
        manifest: ModelManifest,
        layout: ModelInstallLayout,
        downloader: ModelDownloading = URLSessionModelDownloader(),
        verifier: ModelVerifier = ModelVerifier(),
        fileManager: FileManager = .default,
        injectedPromotionFailure: ModelPromotionCheckpoint? = nil
    ) {
        self.manifest = manifest
        self.layout = layout
        self.downloader = downloader
        self.verifier = verifier
        self.fileManager = fileManager
        self.injectedPromotionFailure = injectedPromotionFailure
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
        do {
            try recoverInterruptedPromotion()
        } catch {
            setState(.repairRequired("не удалось восстановить прерванное обновление модели"))
            return state
        }
        sweepStaleStaging()

        guard fileManager.fileExists(atPath: layout.readyMarker.path) else {
            if fileManager.fileExists(atPath: layout.installedDirectory.path) {
                setState(.repairRequired("отсутствует marker готовности модели"))
                return state
            }
            setState(.notInstalled)
            return state
        }

        let marker: ModelReadyMarker
        do {
            let data = try LocalFile.read(layout.readyMarker)
            marker = try JSONDecoder().decode(ModelReadyMarker.self, from: data)
            guard marker.matches(manifest) else {
                throw ModelStoreError.repairRequired("marker модели несовместим с этой версией приложения")
            }
        } catch let error as ModelStoreError {
            setRefreshFailure(error)
            return state
        } catch {
            setState(.repairRequired("marker модели повреждён"))
            return state
        }

        do {
            let metadata = try validateInstalledFiles(marker: marker)
            if marker.installedFiles != metadata {
                try writeReadyMarker(installedFiles: metadata)
            }
        } catch let error as ModelStoreError {
            setRefreshFailure(error)
            return state
        } catch {
            setState(.repairRequired(error.localizedDescription))
            return state
        }

        setState(.ready(directory: layout.installedDirectory))
        return state
    }

    private func setRefreshFailure(_ error: ModelStoreError) {
        if case let .repairRequired(detail) = error {
            setState(.repairRequired(detail))
        } else {
            setState(.failed(error))
        }
    }

    /// Проверить точный inventory и размеры. Если metadata изменилась либо это
    /// marker старого формата, SHA-256 подтверждается до Ready.
    private func validateInstalledFiles(
        marker: ModelReadyMarker
    ) throws -> [ModelReadyMarker.InstalledFile] {
        let expectedPaths = Set(manifest.files.map(\.path))
        let engine = layout.engineDirectory
        guard fileManager.fileExists(atPath: engine.path) else {
            throw ModelStoreError.repairRequired("папка модели отсутствует")
        }

        guard let enumerator = fileManager.enumerator(
            at: engine,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else {
            throw ModelStoreError.repairRequired("не удалось прочитать файлы модели")
        }

        var actualPaths = Set<String>()
        var metadata: [ModelReadyMarker.InstalledFile] = []
        let previous = Dictionary(uniqueKeysWithValues: (marker.installedFiles ?? []).map { ($0.path, $0) })

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ])
            guard values.isSymbolicLink != true else {
                throw ModelStoreError.repairRequired("\(url.lastPathComponent) — символическая ссылка")
            }
            guard values.isRegularFile == true else { continue }

            // Finder создаёт `.DS_Store` при простом просмотре папки. Это его
            // мусор, а не файл модели: убираем и продолжаем, потому что repair
            // здесь означал бы перекачку сотен мегабайт из-за открытого окна.
            if url.lastPathComponent == ".DS_Store" {
                try fileManager.removeItem(at: url)
                continue
            }

            let prefix = engine.standardizedFileURL.path + "/"
            guard url.standardizedFileURL.path.hasPrefix(prefix) else {
                throw ModelStoreError.repairRequired("файл модели вышел за пределы установки")
            }
            let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            actualPaths.insert(path)

            guard let expected = manifest.files.first(where: { $0.path == path }) else {
                throw ModelStoreError.repairRequired("неожиданный файл \(path)")
            }
            let byteCount = Int64(values.fileSize ?? -1)
            guard byteCount == expected.byteCount else {
                throw ModelStoreError.repairRequired("неверный размер \(path)")
            }

            let item = ModelReadyMarker.InstalledFile(
                path: path,
                byteCount: byteCount,
                modifiedAt: values.contentModificationDate
            )
            if previous[path] != item {
                do {
                    try verifier.verify(file: expected, at: url)
                } catch {
                    throw ModelStoreError.repairRequired("повреждён \(path)")
                }
            }
            metadata.append(item)
        }

        guard actualPaths == expectedPaths else {
            let missing = expectedPaths.subtracting(actualPaths).sorted().joined(separator: ", ")
            throw ModelStoreError.repairRequired("не хватает файлов: \(missing)")
        }
        return metadata.sorted { $0.path < $1.path }
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

    /// Довести до консистентного состояния promotion, прерванный между rename.
    private func recoverInterruptedPromotion() throws {
        let destination = layout.installedDirectory
        let backup = layout.backupDirectory
        guard fileManager.fileExists(atPath: backup.path) else { return }

        let destinationHasMarker = fileManager.fileExists(
            atPath: destination.appending(path: ".ready.json").path
        )
        if destinationHasMarker {
            try fileManager.removeItem(at: backup)
        } else {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: backup, to: destination)
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

    /// Явное восстановление, выбранное пользователем. В отличие от `install`,
    /// не доверяет прежнему `.ready`: Core ML warmup мог обнаружить дефект,
    /// который файловый inventory не умеет диагностировать. Старую копию
    /// promotion всё равно держит до полностью проверенной новой.
    public func repair() async {
        guard activeTask == nil else { return }
        let task = Task { await performInstall() }
        activeTask = task
        await task.value
        activeTask = nil
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

            try await collect(staging)
            try Task.checkCancellation()
            try verifyAll(inside: staging)
            try Task.checkCancellation()
            try promote(from: staging)

            excludeFromBackup(layout.modelDirectory)
            setState(.ready(directory: layout.installedDirectory))
        } catch is CancellationError {
            do {
                try removeStaging(staging)
                setState(.notInstalled)
            } catch {
                setState(.failed(.install("загрузка отменена, но partial не удалён: \(error.localizedDescription)")))
            }
        } catch let error as ModelStoreError {
            let primary = String(describing: error)
            do {
                try removeStaging(staging)
                setState(.failed(error))
            } catch {
                setState(.failed(.install("\(primary); staging не удалён: \(error.localizedDescription)")))
            }
        } catch {
            let primary = error.localizedDescription
            do {
                try removeStaging(staging)
                setState(.failed(.install(primary)))
            } catch {
                setState(.failed(.install("\(primary); staging не удалён: \(error.localizedDescription)")))
            }
        }
    }

    private func removeStaging(_ staging: URL) throws {
        guard fileManager.fileExists(atPath: staging.path) else { return }
        try fileManager.removeItem(at: staging)
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

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
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

    /// Crash-safe swap: старая модель остаётся в backup до marker новой.
    private func promote(from staging: URL) throws {
        let destination = layout.installedDirectory
        let backup = layout.backupDirectory
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
            }
            try injectPromotionFailure(at: .afterBackup)
            try fileManager.moveItem(at: staging, to: destination)
            try injectPromotionFailure(at: .afterStagingMove)
            let metadata = try installedMetadataWithoutMarker()
            try writeReadyMarker(installedFiles: metadata)
            try injectPromotionFailure(at: .afterReadyMarker)
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            try injectPromotionFailure(at: .afterBackupRemoval)
        } catch {
            throw ModelStoreError.install(error.localizedDescription)
        }
    }

    private func injectPromotionFailure(at checkpoint: ModelPromotionCheckpoint) throws {
        guard injectedPromotionFailure == checkpoint else { return }
        throw ModelStoreError.install("injected promotion failure: \(checkpoint)")
    }

    private func installedMetadataWithoutMarker() throws -> [ModelReadyMarker.InstalledFile] {
        try manifest.files.map { file in
            let url = try layout.destination(for: file, inside: layout.engineDirectory)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return .init(
                path: file.path,
                byteCount: Int64(values.fileSize ?? -1),
                modifiedAt: values.contentModificationDate
            )
        }.sorted { $0.path < $1.path }
    }

    private func writeReadyMarker(installedFiles: [ModelReadyMarker.InstalledFile]) throws {
        let marker = ModelReadyMarker(
            manifest: manifest,
            verifiedAt: Date(),
            installedFiles: installedFiles
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: layout.readyMarker, options: .atomic)
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
        do {
            if fileManager.fileExists(atPath: layout.modelDirectory.path) {
                try fileManager.removeItem(at: layout.modelDirectory)
            }
            setState(.notInstalled)
        } catch {
            setState(.failed(.install("не удалось удалить модель: \(error.localizedDescription)")))
        }
    }
}
