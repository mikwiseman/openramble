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

    /// Handy's default too; a machine that dictates all day just re-arms the
    /// timer and never notices.
    public static let `default`: IdleUnloadPolicy = .afterFiveMinutes
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
