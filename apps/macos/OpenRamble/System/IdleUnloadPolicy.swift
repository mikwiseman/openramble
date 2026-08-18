import Foundation

/// When to give the engine's ~2.4 GB back after the person stops dictating.
///
/// The zero-settings critical-pressure eviction stays as the floor; this is
/// the opt-out good-citizen layer on top, mirroring Handy's "Unload Model"
/// row down to the seven options. The comeback is designed to be invisible:
/// the key press starts the reload under the voice, and stop waits it out
/// instead of dropping the words.
public enum IdleUnloadPolicy: String, CaseIterable, Identifiable, Sendable {
    case never
    case immediately
    case afterTwoMinutes
    case afterFiveMinutes
    case afterTenMinutes
    case afterFifteenMinutes
    case afterOneHour

    /// Resident by default.
    ///
    /// The five-minute countdown was Handy's default and ours, on the argument
    /// that the comeback is invisible because it rides under the voice. That
    /// holds only while the OS still has the model's specialization cached: it
    /// costs about 0.15 s warm and 13.5–16 s after macOS purges
    /// `com.apple.e5rt.e5bundlecache`, and the purge is routine on a machine
    /// under memory pressure. So the countdown bought back about 2.3 GB during
    /// idle time and, at unpredictable intervals, charged for it at the exact
    /// moment someone had just finished speaking — worst of all on a short
    /// take, which has no speech to hide the reload under.
    ///
    /// Critical memory pressure still evicts a safely idle engine, so the
    /// system keeps its safety valve. The countdown remains available to
    /// anyone who wants the memory back sooner. See `docs/model-lifecycle.md`.
    public static let `default`: IdleUnloadPolicy = .never
    public static let defaultsKey = "modelUnloadTimeout"

    public var id: String { rawValue }

    /// `nil` — keep forever; `.zero` — right after the session ends;
    /// otherwise the idle time before the unload.
    public var idleDelay: Duration? {
        switch self {
        case .never: return nil
        case .immediately: return .zero
        case .afterTwoMinutes: return .seconds(2 * 60)
        case .afterFiveMinutes: return .seconds(5 * 60)
        case .afterTenMinutes: return .seconds(10 * 60)
        case .afterFifteenMinutes: return .seconds(15 * 60)
        case .afterOneHour: return .seconds(60 * 60)
        }
    }

    public var label: String {
        switch self {
        case .never: return "Never"
        case .immediately: return "Immediately"
        case .afterTwoMinutes: return "After 2 minutes"
        case .afterFiveMinutes: return "After 5 minutes"
        case .afterTenMinutes: return "After 10 minutes"
        case .afterFifteenMinutes: return "After 15 minutes"
        case .afterOneHour: return "After 1 hour"
        }
    }

    /// Unknown or absent stored values fall back to the default — a settings
    /// file from the future must not turn into `.never` silently.
    public static func stored(in defaults: UserDefaults) -> IdleUnloadPolicy {
        guard let raw = defaults.string(forKey: defaultsKey),
              let parsed = IdleUnloadPolicy(rawValue: raw)
        else { return .default }
        return parsed
    }
}
