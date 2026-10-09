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
            case .install: return L10n.tr("Download Model — %@ MB", String(describing: downloadMegabytes))
            case .retry: return L10n.tr("Try Again")
            case .repair: return L10n.tr("Redownload Model — %@ MB", String(describing: downloadMegabytes))
            case .cancel: return L10n.tr("Cancel Download")
            case .delete: return L10n.tr("Delete Model")
            }
        }

        /// VoiceOver hint: what will happen when you press it.
        func hint(downloadMegabytes: Int) -> String {
            switch self {
            case .install: return L10n.tr("Downloads about %@ MB. This is the app's only download.", String(describing: downloadMegabytes))
            case .retry: return L10n.tr("Restarts the model download from the beginning.")
            case .repair: return L10n.tr("Downloads and verifies a fresh copy of the model. The damaged copy is not used.")
            case .cancel: return L10n.tr("Stops the download and deletes the partially downloaded files.")
            case .delete: return L10n.tr("Frees up disk space. Dictation stops working until the model is downloaded again.")
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

    /// The whole card in one line, for the places that have room for one — the
    /// menu and the try-out step — or nothing at all.
    ///
    /// A success tone means the model asks nothing of anyone: the files are
    /// usable and, whether the engine is loaded or resting, the next key press
    /// works. Everything else — missing, downloading, verifying, actually
    /// preparing, damaged, failing, being deleted — either needs the person or
    /// is visibly working, and says so.
    ///
    /// The menu used to write this line itself, from a ready model and a cold
    /// engine alone, and so it announced preparation of an engine residency had
    /// put to rest with nothing running. That is the setup screen's own bug on a
    /// second surface. One author for the sentence, and there is no second
    /// opinion to drift.
    var setupLine: String? {
        guard tone != .success else { return nil }
        return progressLabel.map { "\(title) — \($0)" } ?? title
    }

    func title(for action: Action) -> String {
        action.title(downloadMegabytes: downloadMegabytes)
    }

    func hint(for action: Action) -> String {
        action.hint(downloadMegabytes: downloadMegabytes)
    }

    /// The card reads three facts, and never guesses: is the recognizer
    /// usable, is preparation actually running right now, and how far along it
    /// is. Claiming "preparing" from readiness alone is what once left a fresh
    /// install staring at a promise nothing was keeping.
    static func make(
        state: ModelState,
        preparation: EnginePreparationState? = nil,
        place: Place,
        downloadMegabytes: Int = 586,
        isEngineReady: Bool = true,
        isPreparingEngine: Bool = false
    ) -> ModelStatus {
        var status = makeStatus(
            state: state,
            preparation: preparation,
            place: place,
            downloadMegabytes: downloadMegabytes,
            isEngineReady: isEngineReady,
            isPreparingEngine: isPreparingEngine
        )
        status.downloadMegabytes = downloadMegabytes
        return status
    }

    private static func makeStatus(
        state: ModelState,
        preparation: EnginePreparationState?,
        place: Place,
        downloadMegabytes: Int,
        isEngineReady: Bool = true,
        isPreparingEngine: Bool = false
    ) -> ModelStatus {
        switch state {
        case .notInstalled:
            return ModelStatus(
                title: L10n.tr("Model not installed"),
                detail: L10n.tr("%@ MB from the GitHub release mirror; the Hugging Face CDN if it's unavailable. After verification, recognition works without the network.", String(describing: downloadMegabytes)),
                progress: nil,
                progressLabel: nil,
                actions: [.install],
                tone: .neutral,
                announcement: L10n.tr("Model not installed")
            )

        case let .downloading(received, total):
            let label = L10n.tr("%@ of %@ MB", String(describing: megabytes(received)), String(describing: megabytes(total)))
            return ModelStatus(
                title: L10n.tr("Downloading model…"),
                // The same fact serves two different moments: in onboarding the
                // person is mid-checklist and the download must not read as a
                // blocker; in settings they are just visiting.
                detail: place == .onboarding
                    ? L10n.tr("Keep going — grant the permissions below while it downloads.")
                    : L10n.tr("You can keep working — the download won't be interrupted."),
                progress: state.progress,
                progressLabel: label,
                actions: [.cancel],
                tone: .neutral,
                // Exact progress stays available on the ProgressView. Keeping the
                // proactive announcement stable prevents VoiceOver from speaking
                // on every network progress callback.
                announcement: L10n.tr("Downloading model")
            )

        case let .verifying(checked, total):
            let label = L10n.tr("File %@ of %@", String(describing: checked), String(describing: total))
            return ModelStatus(
                title: L10n.tr("Verifying download…"),
                detail: L10n.tr("Checking every file against its checksum."),
                progress: state.progress,
                progressLabel: label,
                actions: [],
                tone: .neutral,
                announcement: L10n.tr("Verifying download")
            )

        case .ready:
            // Three honest states, never blurred: preparing (with real steps),
            // resting (given back on purpose, comes back on the next press),
            // and ready. Saying "preparing" without work behind it is the
            // sentence that made a first run feel broken.
            if !isEngineReady, isPreparingEngine {
                let step = preparation?.step ?? 1
                let total = EnginePreparationState.stepCount
                return ModelStatus(
                    title: L10n.tr("Preparing the model"),
                    // Live seconds, not "usually 20-40": a wait with a moving
                    // counter reads as work, without one it reads as stuck.
                    detail: preparation?.detail
                        ?? L10n.tr("macOS is compiling the model for this Mac. This happens once."),
                    progress: Double(step - 1) / Double(total),
                    progressLabel: preparation.map { L10n.tr("Step %@ of %@ · %@", String(describing: step), String(describing: total), String(describing: $0.title)) }
                        ?? L10n.tr("Step %@ of %@", String(describing: step), String(describing: total)),
                    actions: place == .settings ? [.delete] : [],
                    tone: .neutral,
                    announcement: L10n.tr("Preparing the model, step %@ of %@", String(describing: step), String(describing: total))
                )
            }
            if !isEngineReady {
                return ModelStatus(
                    title: L10n.tr("Model ready"),
                    detail: L10n.tr("The model rests until your next dictation, then loads in a moment."),
                    progress: nil,
                    progressLabel: nil,
                    actions: place == .settings ? [.delete] : [],
                    tone: .success,
                    announcement: L10n.tr("Model ready, resting")
                )
            }
            return ModelStatus(
                title: L10n.tr("Model ready"),
                detail: nil,
                progress: nil,
                progressLabel: nil,
                actions: place == .settings ? [.delete] : [],
                tone: .success,
                announcement: L10n.tr("Model ready")
            )

        case let .repairRequired(detail):
            let reason = message(for: .repairRequired(detail))
            return ModelStatus(
                title: L10n.tr("Model needs repair"),
                detail: reason,
                progress: nil,
                progressLabel: nil,
                actions: [.repair],
                tone: .failure,
                announcement: L10n.tr("Model needs repair. %@", String(describing: reason))
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
                title: requiresRepair ? L10n.tr("Model needs repair") : L10n.tr("Model installation failed"),
                detail: reason,
                progress: nil,
                progressLabel: nil,
                actions: [requiresRepair ? .repair : .retry],
                tone: .failure,
                announcement: requiresRepair
                    ? L10n.tr("Model needs repair. %@", String(describing: reason))
                    : L10n.tr("Model installation failed. %@", String(describing: reason))
            )

        case .deleting:
            return ModelStatus(
                title: L10n.tr("Deleting model…"),
                detail: nil,
                progress: nil,
                progressLabel: nil,
                actions: [],
                tone: .neutral,
                announcement: L10n.tr("Deleting model")
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
            return L10n.tr("Not enough disk space: %@ MB needed, %@ MB free.", String(describing: megabytes(required)), String(describing: megabytes(available)))
        case let .download(detail):
            return L10n.tr("Download failed: %@", String(describing: detail))
        case let .verification(detail):
            return L10n.tr("The download didn't match its checksums: %@", String(describing: detail))
        case let .install(detail):
            return L10n.tr("Couldn't put the files in place: %@", String(describing: detail))
        case let .repairRequired(detail):
            return L10n.tr("The model is damaged or incomplete: %@. Redownload it explicitly.", String(describing: detail))
        case let .manifest(detail):
            return L10n.tr("The model's file list is corrupted: %@", String(describing: detail))
        case let .importSource(detail):
            return L10n.tr("That folder didn't work: %@", String(describing: detail))
        case .cancelled:
            return L10n.tr("Download cancelled.")
        }
    }

    /// Bytes to megabytes - as Finder counts them.
    private static func megabytes(_ bytes: Int64) -> Int {
        Int(bytes / 1_000_000)
    }
}
