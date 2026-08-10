import Foundation
import LocalASR

/// Catalog of recognition languages for the interface.
///
/// The codes come from the engine (the only source of truth that it
/// accepts), names - from the system locale en: hardcoded list of names
/// I would go around with the codes when updating the engine.
enum RecognitionLanguages {
    struct Option: Identifiable, Equatable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let options: [Option] = {
        let english = Locale(identifier: "en_US")
        return FluidAudioAdapter.supportedLanguageHints
            .map { code in
                Option(
                    code: code,
                    name: english.localizedString(forLanguageCode: code)?.capitalized ?? code
                )
            }
            .sorted { $0.name < $1.name }
    }()

    static func name(for code: String?) -> String {
        guard let code else { return "Automatic" }
        return options.first { $0.code == code }?.name ?? code
    }
}
