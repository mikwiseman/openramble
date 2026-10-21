import Foundation
import Observation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case russian = "ru"

    public var id: Self { self }
    public var title: String { self == .english ? "English" : "Русский" }
    public var locale: Locale { Locale(identifier: rawValue) }

    /// The first of the Mac's preferred languages the app speaks, or English.
    public static func preferred(by identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if let language = code.flatMap(AppLanguage.init(rawValue:)) { return language }
        }
        return .english
    }
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

    /// Until the person chooses, speak the Mac's language. Registered, not
    /// stored: the registration domain lives only in this process, so a Mac
    /// switched to another language is followed at the next launch, and a
    /// choice made in Settings outranks it. Called once by the app at launch —
    /// not by tests, which keep the English fallback whatever Mac runs them.
    public func followTheMacUntilChosen(preferredLanguages: [String] = Locale.preferredLanguages) {
        defaults.register(defaults: [
            Self.preferenceKey: AppLanguage.preferred(by: preferredLanguages).rawValue,
        ])
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
