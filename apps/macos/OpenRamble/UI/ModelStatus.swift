import Foundation
import LocalASR

/// What a person sees about the model - in any of its states and on both screens.
///
/// One type for onboarding and settings intentionally: these six states used to be
/// written in two places with different words, and any change had to be
/// enter twice. Second place sooner or later fell behind.
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

        /// The button names the actual volume: full for a clean installation and
        /// only the remainder - when the hint is downloaded after the update.
        func title(downloadMegabytes: Int) -> String {
            switch self {
            case .install: return "Download Model — \(downloadMegabytes) MB"
            case .retry: return "Try Again"
            case .repair: return "Redownload Model — \(downloadMegabytes) MB"
            case .cancel: return "Cancel Download"
            case .delete: return "Delete Model"
            }
        }

        /// VoiceOver hint: what will happen when you press it.
        func hint(downloadMegabytes: Int) -> String {
            switch self {
            case .install: return "Downloads about \(downloadMegabytes) MB. This is the app's only download."
            case .retry: return "Restarts the model download from the beginning."
            case .repair: return "Downloads and verifies a fresh copy of the model. The damaged copy is not used."
            case .cancel: return "Stops the download and deletes the partially downloaded files."
            case .delete: return "Frees up disk space. Dictation stops working until the model is downloaded again."
            }
        }
    }

    /// Where it is shown - only the set of buttons depends on this.
    enum Place {
        case onboarding
        case settings
    }

    var title: String
    var detail: String?
    /// Percentage of completion, if meaningful.
    var progress: Double?
    /// The caption for the indicator is also the value for VoiceOver.
    var progressLabel: String?
    var actions: [Action]
    var tone: Tone
    /// What to announce to VoiceOver when the state changes.
    var announcement: String
    /// How much the install/repair button will download - the full volume or the remainder.
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
        preparation: EnginePreparationState? = nil,
        place: Place,
        downloadMegabytes: Int = 586
    ) -> ModelStatus {
        var status = makeStatus(
            state: state,
            isPreparingEngine: isPreparingEngine,
            preparation: preparation,
            place: place,
            downloadMegabytes: downloadMegabytes
        )
        status.downloadMegabytes = downloadMegabytes
        return status
    }

    private static func makeStatus(
        state: ModelState,
        isPreparingEngine: Bool,
        preparation: EnginePreparationState?,
        place: Place,
        downloadMegabytes: Int
    ) -> ModelStatus {
        switch state {
        case .notInstalled:
            return ModelStatus(
                title: "Model not installed",
                detail: "\(downloadMegabytes) MB from the Hugging Face CDN; a GitHub mirror if it's unavailable. After verification, recognition works without the network.",
                progress: nil,
                progressLabel: nil,
                actions: [.install],
                tone: .neutral,
                announcement: "Model not installed"
            )

        case let .downloading(received, total):
            let label = "\(megabytes(received)) of \(megabytes(total)) MB"
            return ModelStatus(
                title: "Downloading model…",
                detail: "You can keep working — the download won't be interrupted.",
                progress: state.progress,
                progressLabel: label,
                actions: [.cancel],
                tone: .neutral,
                // Exact progress stays available on the ProgressView. Keeping the
                // proactive announcement stable prevents VoiceOver from speaking
                // on every network progress callback.
                announcement: "Downloading model"
            )

        case let .verifying(checked, total):
            let label = "File \(checked) of \(total)"
            return ModelStatus(
                title: "Verifying download…",
                detail: "Checking every file against its checksum.",
                progress: state.progress,
                progressLabel: label,
                actions: [],
                tone: .neutral,
                announcement: "Verifying download"
            )

        case .ready:
            return ModelStatus(
                title: "Model ready",
                // While the first loading into the neuromodule is in progress, the person sees
                // “ready”, but the dictation will still think about it. To remain silent about this means
                // get a complaint about being slow the first time.
                // Live seconds, not "usually 20–40": waiting with the going
                // with the counter it is read as work, and without it it is read as stuck.
                detail: isPreparingEngine
                    ? (preparation?.title ?? "Preparing for this Mac — usually 20–40 seconds, and only once.")
                    : nil,
                progress: nil,
                progressLabel: nil,
                actions: place == .settings ? [.delete] : [],
                tone: .success,
                announcement: isPreparingEngine ? "Model ready, preparing for first use" : "Model ready"
            )

        case let .repairRequired(detail):
            let reason = message(for: .repairRequired(detail))
            return ModelStatus(
                title: "Model needs repair",
                detail: reason,
                progress: nil,
                progressLabel: nil,
                actions: [.repair],
                tone: .failure,
                announcement: "Model needs repair. \(reason)"
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
                title: requiresRepair ? "Model needs repair" : "Model installation failed",
                detail: reason,
                progress: nil,
                progressLabel: nil,
                actions: [requiresRepair ? .repair : .retry],
                tone: .failure,
                announcement: requiresRepair
                    ? "Model needs repair. \(reason)"
                    : "Model installation failed. \(reason)"
            )

        case .deleting:
            return ModelStatus(
                title: "Deleting model…",
                detail: nil,
                progress: nil,
                progressLabel: nil,
                actions: [],
                tone: .neutral,
                announcement: "Deleting model"
            )
        }
    }

    /// Error in human words.
    ///
    /// Previously, `String(describing:)` was printed here - that is, the person saw
    /// `notEnoughDiskSpace(requiredBytes: 594000000, availableBytes: 1200000)`
    /// and should have guessed that there was no space on the disk.
    static func message(for error: ModelStoreError) -> String {
        switch error {
        case let .notEnoughDiskSpace(required, available):
            return """
                Not enough disk space: \(megabytes(required)) MB needed, \
                \(megabytes(available)) MB free.
                """
        case let .download(detail):
            return "Download failed: \(detail)"
        case let .verification(detail):
            return "The download didn't match its checksums: \(detail)"
        case let .install(detail):
            return "Couldn't put the files in place: \(detail)"
        case let .repairRequired(detail):
            return "The model is damaged or incomplete: \(detail). Redownload it explicitly."
        case let .manifest(detail):
            return "The model's file list is corrupted: \(detail)"
        case let .importSource(detail):
            return "That folder didn't work: \(detail)"
        case .cancelled:
            return "Download cancelled."
        }
    }

    /// Bytes to megabytes - as Finder counts them.
    private static func megabytes(_ bytes: Int64) -> Int {
        Int(bytes / 1_000_000)
    }
}
