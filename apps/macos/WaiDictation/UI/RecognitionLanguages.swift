import Foundation
import LocalASR

/// Каталог языков распознавания для интерфейса.
///
/// Коды приходят от движка (единственный источник правды о том, что он
/// принимает), имена — из системной локали en: захардкоженный список имён
/// разъезжался бы с кодами при обновлении движка.
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
