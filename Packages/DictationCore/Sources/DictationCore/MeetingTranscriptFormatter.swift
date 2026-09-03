import Foundation

/// A transcript as text — for the clipboard, a file, or another app.
///
/// Speaker names come from the channel at render time, so relabelling is a
/// metadata edit rather than a rewrite. Timestamps are always included: a
/// checkbox for them is exactly the kind of option this app refuses, and
/// removing them is a find-and-replace in any editor. Pure.
public enum MeetingTranscriptFormatter {
    public static let defaultNames: [MeetingChannel: String] = [.microphone: "You", .system: "Others"]
    public static let failedLine = "[couldn't transcribe this part]"

    public static func plainText(
        _ utterances: [MeetingUtterance],
        names: [MeetingChannel: String] = defaultNames
    ) -> String {
        ordered(utterances).map { utterance in
            "\(name(utterance.channel, names)) · \(timestamp(utterance.start))\n\(body(utterance))"
        }.joined(separator: "\n\n")
    }

    /// - Parameters:
    ///   - note: a line that survives in the artefact — "only the microphone
    ///     was recorded" — when the recording was one-sided.
    public static func markdown(
        _ utterances: [MeetingUtterance],
        title: String,
        subtitle: String,
        note: String? = nil,
        names: [MeetingChannel: String] = defaultNames
    ) -> String {
        var lines = ["# \(title)", "", subtitle, "", "> Recorded with OpenRamble. This transcript was produced on this Mac."]
        if let note { lines += ["", "> \(note)"] }
        for utterance in ordered(utterances) {
            lines += ["", "**\(name(utterance.channel, names))** · \(timestamp(utterance.start))", body(utterance)]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `hh:mm:ss`, always three fields, so a column of them lines up.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    private static func ordered(_ utterances: [MeetingUtterance]) -> [MeetingUtterance] {
        utterances.sorted { $0.start < $1.start }
    }

    private static func name(_ channel: MeetingChannel, _ names: [MeetingChannel: String]) -> String {
        names[channel] ?? defaultNames[channel] ?? channel.rawValue
    }

    private static func body(_ utterance: MeetingUtterance) -> String {
        utterance.isFailed ? failedLine : utterance.text
    }
}
