import Foundation

/// The engine folder recognition loads from.
///
/// Read at every preparation rather than captured once at launch, so moving
/// from the previous model to the current one takes effect at the next load
/// without rebuilding the dictation controller. The owner unloads the engine
/// when it changes the folder; this box only answers which folder is current.
final class ActiveModelDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL

    init(_ url: URL) {
        self.url = url
    }

    var current: URL {
        lock.withLock { url }
    }

    /// Whether the folder changed.
    @discardableResult
    func set(_ newValue: URL) -> Bool {
        lock.withLock {
            defer { url = newValue }
            return url != newValue
        }
    }
}
