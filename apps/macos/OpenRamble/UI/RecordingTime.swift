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
    static func spoken(_ seconds: TimeInterval, language: AppLanguage = L10n.shared.language) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(spokenUnit(hours, "hour", language: language)) }
        if minutes > 0 { parts.append(spokenUnit(minutes, "minute", language: language)) }
        if secs > 0 || parts.isEmpty { parts.append(spokenUnit(secs, "second", language: language)) }
        return parts.joined(separator: " ")
    }

    /// For a header: whole minutes once past one, seconds before that.
    /// Floored like `clock`, so the two never disagree about the same file.
    static func brief(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 { return L10n.tr("%@ s", String(describing: total)) }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 { return minutes > 0 ? L10n.tr("%@ h %@ min", String(describing: hours), String(describing: minutes)) : L10n.tr("%@ h", String(describing: hours)) }
        return L10n.tr("%@ min", String(describing: minutes))
    }

    static func spokenUnit(_ value: Int, _ name: String, language: AppLanguage = L10n.shared.language) -> String {
        let form: String
        if language == .russian {
            let lastTwo = value % 100, last = value % 10
            form = (11...14).contains(lastTwo) ? "many" : (last == 1 ? "one" : ((2...4).contains(last) ? "few" : "many"))
        } else {
            form = value == 1 ? "one" : "many"
        }
        return "\(value) \(L10n.tr("\(name).\(form)", language: language))"
    }
}
