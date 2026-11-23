import SwiftUI

/// The iPhone's type and colour, on top of the shared `GlassTokens`.
///
/// The person's words are set in New York, the system serif, at regular
/// weight; the app's own words stay in SF. One colour has one meaning across
/// OpenRamble: red is recording and nothing else.
enum Theme {
    /// A take's words in the list.
    static let words = Font.system(.title3, design: .serif)
    /// A take's words on its own page.
    static let page = Font.system(.title2, design: .serif)
    /// Headlines: few, large, regular weight.
    static let display = Font.system(.largeTitle, design: .serif)
    /// Times, durations, days.
    static let caption = Font.footnote.monospacedDigit()

    /// Recording, and only recording.
    static let recording = Color(red: 1, green: 0.231, blue: 0.188)

    /// The page's side margin.
    static let margin: CGFloat = 28
    /// Air between two takes.
    static let takeSpacing: CGFloat = 36
    /// Line spacing for words, so a paragraph reads like a page and not a form.
    static let leading: CGFloat = 5
}

extension Take {
    /// "9:41 PM · 0:12"
    var caption: String {
        let time = recordedAt.formatted(date: .omitted, time: .shortened)
        return duration > 0 ? "\(time)  ·  \(Self.clock(duration))" : time
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
