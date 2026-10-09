import Foundation
import Observation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case russian = "ru"

    public var id: Self { self }
    public var title: String { self == .english ? "English" : "Русский" }
    public var locale: Locale { Locale(identifier: rawValue) }
}

/// One preference for SwiftUI, AppKit and messages produced off the main thread.
/// The registrar observes the UserDefaults-backed property without duplicating
/// its storage. Changing it redraws translated text without rebuilding windows
/// or losing an unfinished recording or edit.
public final class L10n: Observable, Sendable {
    public static let shared = L10n()
    public static let preferenceKey = "interfaceLanguage"
    private let observation = ObservationRegistrar()
    private let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public var language: AppLanguage {
        get {
            observation.access(self, keyPath: \.language)
            return defaults.string(forKey: Self.preferenceKey)
                .flatMap(AppLanguage.init(rawValue:)) ?? .english
        }
        set {
            observation.withMutation(of: self, keyPath: \.language) {
                defaults.set(newValue.rawValue, forKey: Self.preferenceKey)
                // System-owned panels and permission prompts use this on the
                // next launch; the app's own text switches immediately.
                defaults.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    public static func tr(_ key: String, _ arguments: CVarArg..., language: AppLanguage? = nil) -> String {
        let selected = language ?? shared.language
        let resources = Bundle.module
        let bundle = resources.path(forResource: selected.rawValue, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? resources
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: selected.locale, arguments: arguments)
    }
}
