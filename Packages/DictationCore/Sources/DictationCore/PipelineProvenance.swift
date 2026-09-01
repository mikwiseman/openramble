import Foundation

/// The origin of the last dictation: what it became, and what it must not lose.
///
/// Two consumers. Correction learning needs `finalText` and `spans`: it diffs
/// what was inserted against what the person changed, and must not turn an edit
/// inside a path or backticks into a silent rule. And `afterDictionary` is the
/// checkpoint the conformance fixtures record, which is how the Swift pipeline
/// and its Rust port are held to the same behaviour at the dictionary stage.
///
/// The recognized text itself is deliberately not kept. It was here only for a
/// "Copy Last as Spoken" menu item, and carrying a verbatim copy of every
/// dictation for a feature nobody invoked is a cost with no reader.
///
/// **Intentionally not `Codable`.** This is not forgetfulness, but the guarantee itself “never for
/// disk": to write such a structure to a file, you first have to consciously
/// add conformation, and next to it is a test that falls on it.
///
/// `description` returns only field names and character counters - none
/// random interpolation into the log will not bring the dictated text out.
public struct PipelineProvenance: Sendable, Equatable, CustomStringConvertible {
    /// The state after the dictionary entirely and before any cosmetics.
    public let afterDictionary: String
    /// What will be inserted.
    public let finalText: String
    /// Protected spans of the final text.
    ///
    /// They lie here because training on edits must bypass them, and
    /// it has no other honest source: it only sees the inserted text.
    public let spans: [ProtectedSpan]

    public init(afterDictionary: String, finalText: String, spans: [ProtectedSpan]) {
        self.afterDictionary = afterDictionary
        self.finalText = finalText
        self.spans = spans
    }

    public var description: String {
        "PipelineProvenance(afterDictionary: \(afterDictionary.count) chars, "
            + "final: \(finalText.count) chars, spans: \(spans.count))"
    }
}
