import Foundation

/// Раскладка файлов модели на диске.
///
/// Установка идёт через промежуточную директорию: файлы качаются в staging,
/// проверяются там же и только потом переезжают на финальное место одним
/// переименованием. Половинчатой установки, которую можно принять за рабочую,
/// не существует по построению.
public struct ModelInstallLayout: Sendable {
    /// Корень: ~/Library/Application Support/WaiDictation/Models
    public let root: URL
    public let modelID: String
    public let revision: String

    public init(root: URL, modelID: String, revision: String, engineFolderName: String) {
        self.root = root
        self.modelID = modelID
        self.revision = revision
        self.engineFolderName = engineFolderName
    }

    public init(manifest: ModelManifest, root: URL? = nil) throws {
        let base: URL
        if let root {
            base = root
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            base = support.appending(path: "WaiDictation/Models", directoryHint: .isDirectory)
        }
        // Имя папки библиотека получает из имени репозитория, отбрасывая суффикс
        // «-coreml». Проверено по коду тега 0.15.5.
        let folder = (manifest.repository.split(separator: "/").last.map(String.init) ?? manifest.modelID)
            .replacingOccurrences(of: "-coreml", with: "")
        self.init(
            root: base,
            modelID: manifest.modelID,
            revision: manifest.revision,
            engineFolderName: folder
        )
    }

    /// Директория конкретной модели.
    public var modelDirectory: URL {
        root.appending(path: modelID, directoryHint: .isDirectory)
    }

    /// Имя папки, которого требует FluidAudio.
    ///
    /// Библиотека вычисляет путь как «родитель переданной директории + имя
    /// репозитория», хотя её документация обещает, что достаточно передать
    /// папку с бандлами. Расхождение проверено на коде тега 0.15.5, поэтому
    /// раскладка подстраивается под фактическое поведение.
    public let engineFolderName: String

    /// Финальное место установки. В имени — ревизия, поэтому смена ревизии
    /// не портит уже установленную модель и позволяет откатиться.
    public var installedDirectory: URL {
        modelDirectory.appending(path: revision, directoryHint: .isDirectory)
    }

    /// Директория, которую нужно передавать в FluidAudio.
    public var engineDirectory: URL {
        installedDirectory.appending(path: engineFolderName, directoryHint: .isDirectory)
    }

    /// Куда складывать файлы внутри промежуточной директории установки.
    public func engineDirectory(inside staging: URL) -> URL {
        staging.appending(path: engineFolderName, directoryHint: .isDirectory)
    }

    /// Метка готовности. Пишется последней; её наличие означает, что все файлы
    /// на месте и проверены.
    public var readyMarker: URL {
        installedDirectory.appending(path: ".ready.json", directoryHint: .notDirectory)
    }

    /// Директория для конкретной попытки установки. Уникальна, чтобы две
    /// параллельные попытки не топтали друг друга.
    public func stagingDirectory(attempt: UUID) -> URL {
        modelDirectory.appending(path: ".staging-\(attempt.uuidString)", directoryHint: .isDirectory)
    }

    /// Путь файла внутри директории установки.
    ///
    /// Путь из манифеста уже проверен на выход за пределы директории, но здесь
    /// это проверяется повторно: слишком дорогая ошибка, чтобы полагаться на
    /// один барьер.
    public func destination(for file: ModelManifest.File, inside directory: URL) throws -> URL {
        let resolved = directory.appending(path: file.path, directoryHint: .notDirectory)
        // Сравниваем по компонентам пути, а не по префиксу строки. Префикс
        // строки пропускает соседнюю директорию с тем же началом имени:
        // «…/parakeet» — префикс «…/parakeet-подделка», и путь вида
        // «../parakeet-подделка/файл» прошёл бы проверку, оставаясь снаружи.
        let base = directory.standardizedFileURL.pathComponents
        let target = resolved.standardizedFileURL.pathComponents
        guard target.count > base.count, Array(target.prefix(base.count)) == base else {
            throw ModelInstallError.unsafePath(file.path)
        }
        return resolved
    }
}

public enum ModelInstallError: Error, Sendable, Equatable {
    case unsafePath(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case promoteFailed(String)
}

// MARK: - Метка готовности

/// Содержимое `.ready.json`.
///
/// Хранит ровно то, что нужно, чтобы понять: установленное соответствует тому,
/// что мы сейчас ожидаем. Если ревизия или версия FluidAudio разошлись —
/// установка считается непригодной, а не «наверное, сойдёт».
public struct ModelReadyMarker: Codable, Sendable, Equatable {
    public let revision: String
    public let fluidAudioVersion: String
    public let fileCount: Int
    public let totalByteCount: Int64
    public let verifiedAt: Date

    public init(
        revision: String,
        fluidAudioVersion: String,
        fileCount: Int,
        totalByteCount: Int64,
        verifiedAt: Date
    ) {
        self.revision = revision
        self.fluidAudioVersion = fluidAudioVersion
        self.fileCount = fileCount
        self.totalByteCount = totalByteCount
        self.verifiedAt = verifiedAt
    }

    public init(manifest: ModelManifest, verifiedAt: Date) {
        self.init(
            revision: manifest.revision,
            fluidAudioVersion: manifest.fluidAudioVersion,
            fileCount: manifest.files.count,
            totalByteCount: manifest.totalByteCount,
            verifiedAt: verifiedAt
        )
    }

    /// Соответствует ли установленное текущему манифесту.
    public func matches(_ manifest: ModelManifest) -> Bool {
        revision == manifest.revision
            && fluidAudioVersion == manifest.fluidAudioVersion
            && fileCount == manifest.files.count
            && totalByteCount == manifest.totalByteCount
    }
}
