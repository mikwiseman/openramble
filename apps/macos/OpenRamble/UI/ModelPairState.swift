import Foundation
import LocalASR

/// Combining the states of two models into one that a person can see.
///
/// For humans, recognition and acoustic prompting of terms is one
/// “model”: one download button, one progress, one destiny. There are two inside
/// independent repositories with their own manifests, and the union rule is pure
/// politics with tests, not logic in the view model.
enum ModelPairState {
    /// Priority order: breakdown loudest, removal and work next,
    /// readiness - only when both are ready.
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

        // Installation proceeds sequentially: first the main one, then the prompt.
        // Progress is shared and does not jump back at the border between them.
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

    /// How many bytes the download button will actually fetch: the full amount
    /// for a clean installation, only the remainder for collection after
    /// updating the application.
    ///
    /// `engineRejectedModels` is asked for rather than defaulted, because
    /// forgetting it is exactly how the screen came to offer "Redownload Model
    /// — 0 MB". After Core ML refuses an intact copy, both stores still report
    /// `.ready`, so nothing is missing from disk — and yet `installModel`
    /// repairs both models, which is a full download. The number was patched at
    /// its two call sites with `== 0 ? 586`, a default that hid a wrong answer
    /// instead of computing the right one.
    static func remainingBytes(
        main: ModelState,
        vocabulary: ModelState,
        mainTotalBytes: Int64,
        vocabularyTotalBytes: Int64,
        engineRejectedModels: Bool
    ) -> Int64 {
        if engineRejectedModels { return mainTotalBytes + vocabularyTotalBytes }
        var bytes: Int64 = 0
        if !main.isReady { bytes += mainTotalBytes }
        if !vocabulary.isReady { bytes += vocabularyTotalBytes }
        return bytes
    }
}
