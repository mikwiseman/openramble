import Foundation
import os

/// Tap between the audio stream and the recognition preview.
///
/// The capture callback comes outside the main actor and cannot look into
/// setting `@Published showLivePreview`. The shutter is a common point of truth:
/// the main actor opens and closes, the audio path only reads. Closed
/// shutter saves the task for each frame (~23 per second) and ensures that
/// When the preview is turned off, not a single count is included.
final class PreviewFeedGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isOpen: Bool {
        state.withLock { $0 }
    }

    func open() {
        state.withLock { $0 = true }
    }

    func close() {
        state.withLock { $0 = false }
    }
}
