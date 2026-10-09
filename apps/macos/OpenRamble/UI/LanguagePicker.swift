import SwiftUI

struct LanguagePicker: View {
    var body: some View {
        Picker(L10n.tr("Language"), selection: Binding(
            get: { L10n.shared.language },
            set: { L10n.shared.language = $0 }
        )) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.title).tag(language)
            }
        }
        .accessibilityIdentifier("interface-language")
    }
}
