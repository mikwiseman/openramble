import Foundation

/// The origin of the last dictation: what the text was and what it has become.
///
/// Two things are needed: “copy verbatim” - so that what is said is accessible even
/// after the dictionary and polisher have worked on it - and diagnostics,
/// which separates “the dictionary didn’t work” from “it worked, but the cosmetics moved.”
///
/// **Intentionally not `Codable`.** This is not forgetfulness, but the guarantee itself “never for
/// disk": to write such a structure to a file, you first have to consciously
/// add conformation, and next to it is a test that falls on it.
///
/// `description` returns only field names and character counters - none
/// random interpolation into the log will not bring the dictated text out.
public struct PipelineProvenance: Sendable, Equatable, CustomStringConvertible {
    /// Exactly what the recognition returned, up to all stages.
    public let raw: String
    /// The state after the dictionary entirely and before any cosmetics.
    public let afterDictionary: String
    /// What will be inserted.
    public let finalText: String
    /// Protected spans of the final text.
    ///
    /// They lie here because training on edits must bypass them, and
    /// it has no other honest source: it only sees the inserted text.
    public let spans: [ProtectedSpan]

    public init(raw: String, afterDictionary: String, finalText: String, spans: [ProtectedSpan]) {
        self.raw = raw
        self.afterDictionary = afterDictionary
        self.finalText = finalText
        self.spans = spans
    }

    public var description: String {
        "PipelineProvenance(raw: \(raw.count) chars, afterDictionary: \(afterDictionary.count) chars,"
            + "final: \(finalText.count) chars, spans: \(spans.count))"
    }
}
