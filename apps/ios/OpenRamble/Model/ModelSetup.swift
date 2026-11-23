import Foundation
import LocalASR
import Observation

/// The voice model, as the person sees it: absent, arriving, or ready.
///
/// A thin view of LocalASR's `ModelStore`, which does the real work exactly as
/// on the Mac: download to a staging folder, check every byte against the
/// manifest's SHA-256, then move the model into place in one step.
@MainActor
@Observable
final class ModelSetup {
    enum Phase: Equatable {
        case checking
        case absent
        case downloading(received: Int64, total: Int64)
        case verifying
        case ready(URL)
        case failed(String)
        case removing
    }

    private(set) var phase: Phase = .checking
    /// The model's size in bytes, from the manifest the app ships with.
    let byteCount: Int64
    private let store: ModelStore?
    private var observation: Task<Void, Never>?
    private var install: Task<Void, Never>?

    init(store: ModelStore?, byteCount: Int64) {
        self.store = store
        self.byteCount = byteCount
        if store == nil { phase = .failed("The app's model description is missing.") }
    }

    /// The app's setup: the bundled manifest, Application Support/Models,
    /// excluded from iCloud Backup, fetched by the background downloader.
    static func standard() -> ModelSetup {
        guard let manifest = try? ModelManifest.bundled() else {
            return ModelSetup(store: nil, byteCount: 0)
        }
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        var root = support.appending(path: "Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        guard let layout = try? ModelInstallLayout(manifest: manifest, root: root) else {
            return ModelSetup(store: nil, byteCount: 0)
        }
        let store = ModelStore(manifest: manifest, layout: layout, downloader: BackgroundModelDownloader.shared)
        return ModelSetup(store: store, byteCount: manifest.files.reduce(0) { $0 + $1.byteCount })
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    /// Reads the disk and follows the store from then on, telling `onChange`
    /// about every new phase.
    func start(onChange: @escaping @MainActor (Phase) async -> Void) {
        guard let store, observation == nil else { return }
        observation = Task { [weak self] in
            _ = await store.refreshState()
            for await state in await store.states() {
                let phase = Self.phase(for: state)
                guard let self, phase != self.phase || phase == .checking else { continue }
                self.phase = phase
                await onChange(phase)
            }
        }
    }

    func download() {
        guard let store, install == nil else { return }
        install = Task { [weak self] in
            await store.install()
            self?.install = nil
        }
    }

    #if DEBUG
    /// Installs the model from a folder holding its file, through the same
    /// checksum check as a download: `-import-model /path/to/folder`. For the
    /// Simulator; not compiled into release builds.
    func importFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let store, let index = arguments.firstIndex(of: "-import-model"),
              arguments.indices.contains(index + 1) else { return }
        let folder = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        install = Task { [weak self] in
            await store.importModel(from: folder)
            self?.install = nil
        }
    }
    #endif

    func cancel() {
        guard let store else { return }
        Task { await store.cancelInstall() }
    }

    func remove() async {
        guard let store else { return }
        await store.delete()
    }

    /// The store's states, in the words the person reads.
    static func phase(for state: ModelState) -> Phase {
        switch state {
        case .notInstalled:
            return .absent
        case let .downloading(received, total):
            return .downloading(received: received, total: total)
        case .verifying:
            return .verifying
        case let .ready(directory):
            return .ready(directory)
        case .repairRequired:
            // An install that was interrupted: downloading again repairs it.
            return .absent
        case let .failed(error):
            return error == .cancelled ? .absent : .failed(describe(error))
        case .deleting:
            return .removing
        }
    }

    static func describe(_ error: ModelStoreError) -> String {
        switch error {
        case .notEnoughDiskSpace(let required, let available):
            let format = ByteCountFormatStyle(style: .file)
            return "There isn't enough free space. The model needs \(required.formatted(format)); this iPhone has \(available.formatted(format)) free."
        case .download(let reason):
            return "The download stopped: \(reason). Try again when you're online."
        case .verification:
            return "The download arrived damaged and was discarded. Try again."
        case .manifest, .install, .repairRequired, .importSource:
            return "The model could not be installed. Try again."
        case .cancelled:
            return "The download was cancelled."
        }
    }
}
