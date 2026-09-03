import Foundation

/// What a shared recording is called once it leaves the app.
///
/// The name is the person's own title, because that is what they will look
/// for in a Downloads folder a month later. It only has to survive being a
/// file name: separators and colons would silently become subdirectories or
/// be rejected, a leading dot would hide it, and some filesystems stop at
/// 255 bytes. A title made entirely of those characters leaves nothing, so
/// the date stands in rather than an empty name. Pure.
public enum MeetingExportNaming {
    /// Characters that cannot appear in a file name on the systems these
    /// files travel to. `:` is a separator to the Finder, `/` to everything.
    private static let forbidden = CharacterSet(charactersIn: "/\\:\u{0}")

    public static func fileName(_ title: String, fallback: String) -> String {
        let cleaned = title.components(separatedBy: forbidden).joined(separator: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var name = cleaned.isEmpty ? fallback : cleaned
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = fallback }
        // Room for an extension inside the 255-byte limit, cut on a character
        // boundary so a name never ends mid-emoji.
        while name.utf8.count > 200 { name.removeLast() }
        return name.trimmingCharacters(in: .whitespaces)
    }
}
