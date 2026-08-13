import Foundation

/// When a recording starts, is the engine cold enough to warm in parallel?
///
/// The recognition engine has two speeds, measured on this hardware: 0.13 s
/// warm against 16.06 s after macOS evicted its Neural Engine state. The
/// eviction happens with idle time — memory pressure, sleep — so the moment
/// the person presses the key is the perfect place to pay for the reload:
/// they are about to speak for seconds anyway, and the warm-up runs under
/// their voice instead of after it.
///
/// The five-minute threshold keeps the ping out of active work entirely:
/// back-to-back dictations never trigger it, only a return from real idle.
enum EngineWarming {
    static let coldSuspicionInterval: TimeInterval = 300

    static func shouldWarm(lastEngineActivity: Date?, now: Date) -> Bool {
        guard let lastEngineActivity else { return true }
        return now.timeIntervalSince(lastEngineActivity) >= coldSuspicionInterval
    }
}
