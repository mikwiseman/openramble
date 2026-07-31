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

    private func performInstall() async {
        let attempt = UUID()
        let staging = layout.stagingDirectory(attempt: attempt)

        do {
            try preflightDiskSpace()
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }

            try await downloadAll(into: staging)
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

            guard let url = manifest.downloadURL(for: file) else {
                throw ModelStoreError.manifest("не построился адрес для \(file.path)")
            }
            let destination = try layout.destination(for: file, inside: layout.engineDirectory(inside: staging))
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let alreadyDone = completed
            let temporary: URL
            do {
                temporary = try await downloader.download(
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
                throw ModelStoreError.download("\(file.path): \(error)")
            }

            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
            completed += file.byteCount
            setState(.downloading(receivedBytes: completed, totalBytes: total))
        }
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
