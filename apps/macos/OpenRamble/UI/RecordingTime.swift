import Foundation

/// Durations and positions as the window shows them and as VoiceOver says
/// them.
///
/// The two forms are kept side by side because they must agree: a scrubber
/// whose label reads "48:12" and whose spoken value says "48 em" has taught
/// a blind person to distrust the label.
enum RecordingTime {
    /// `m:ss` under an hour, `h:mm:ss` from then on. Negative reads as zero.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// The same value in words: "48 minutes 12 seconds".
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if secs > 0 || parts.isEmpty { parts.append(unit(secs, "second")) }
        return parts.joined(separator: " ")
    }

    /// For a header: whole minutes once past one, seconds before that.
    /// Floored like `clock`, so the two never disagree about the same file.
    static func brief(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 { return "\(total) s" }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        return "\(minutes) min"
    }

    private static func unit(_ value: Int, _ name: String) -> String {
        "\(value) \(name)\(value == 1 ? "" : "s")"
    }
}
