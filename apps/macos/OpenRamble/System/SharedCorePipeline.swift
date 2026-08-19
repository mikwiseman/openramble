import DictationCore
import Foundation
import RambleCore

/// The text pipeline, run by the shared core.
///
/// This is the point of the cross-platform work: the rules that turn recognized
/// speech into text a person sees are written once and every platform runs the
/// same ones. Until now the Mac had its own copy and Windows had another.
///
/// `DictationCore` keeps its Swift pipeline, and that is deliberate rather than
/// leftover. The conformance fixtures are recordings of it, and they are what
/// proves the two implementations agree — if the package delegated here too,
/// the fixtures would be recordings of the thing they are meant to check.
struct SharedCorePipeline: TextProcessing {
    let replacements: [DictionaryReplacement]
    let allowPressReturnCommand: Bool

    init(replacements: [DictionaryReplacement], allowPressReturnCommand: Bool = false) {
        self.replacements = replacements
        self.allowPressReturnCommand = allowPressReturnCommand
    }

    func run(_ recognized: String) -> TextPipeline.Run {
        let result = processText(
            recognized: recognized,
            replacements: replacements.map {
                FfiReplacement(
                    id: $0.id.uuidString,
                    spoken: $0.spoken,
                    written: $0.written,
                    inflects: $0.inflects,
                    noAcousticBoost: $0.noAcousticBoost,
                    allowsPhoneticMatching: $0.allowsPhoneticMatching
                )
            },
            allowPressReturnCommand: allowPressReturnCommand,
            phoneticMatching: true
        )

        return TextPipeline.Run(
            output: TextPipeline.Output(
                text: result.text,
                command: result.command.map {
                    switch $0 {
                    case .pressReturn: return TrailingCommand.pressReturn
                    case .newLine: return TrailingCommand.newLine
                    }
                }
            ),
            provenance: PipelineProvenance(
                raw: recognized,
                afterDictionary: result.afterDictionary,
                finalText: result.text,
                spans: result.spans.map {
                    ProtectedSpan(
                        kind: $0.kind.asDictationCore,
                        // Character offsets on both sides. The core counts in
                        // characters precisely so this conversion is an identity
                        // rather than a place to lose a Cyrillic prefix.
                        range: Int($0.start)..<Int($0.end),
                        text: $0.text
                    )
                }
            )
        )
    }
}

private extension FfiSpanKind {
    var asDictationCore: ProtectedSpan.Kind {
        switch self {
        case .backticks: return .backticks
        case .path: return .path
        case .flag: return .flag
        case .identifier: return .identifier
        }
    }
}
