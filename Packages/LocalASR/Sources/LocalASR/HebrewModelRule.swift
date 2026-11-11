import Foundation

/// When the optional Hebrew model is offered, and when it recognizes a take.
///
/// The model the app ships hears 25 European languages and no Hebrew, and the
/// Hebrew model hears Hebrew only. A language setting would have to be changed
/// before every take by anyone who writes in two languages, so there is none:
/// a take is recognized in the language of the keyboard, which the person
/// already switches to type and which the menu bar already shows.
///
/// The same fact decides who is asked. A Mac without a Hebrew keyboard could
/// never use the model, so it is never offered there, and nobody else sees a
/// row about a language they do not write.
public struct HebrewModelRule: Sendable, Equatable {
    /// Show the download: this Mac has a Hebrew keyboard, or something of the
    /// model is already on disk and must stay removable.
    public let isOffered: Bool
    /// The next take is recognized with the Hebrew model.
    public let recognizes: Bool

    /// - Parameters:
    ///   - keyboardLanguage: the language of the keyboard in use now.
    ///   - enabledKeyboardLanguages: the languages of every keyboard this Mac
    ///     can switch to.
    ///   - model: what the disk holds of the Hebrew model.
    public init(keyboardLanguage: String?, enabledKeyboardLanguages: [String], model: ModelState) {
        isOffered = enabledKeyboardLanguages.contains(where: Self.isHebrew) || model != .notInstalled
        recognizes = model.isReady && keyboardLanguage.map(Self.isHebrew) == true
    }

    /// Hebrew is "he", with or without a region, and "iw" in older data.
    static func isHebrew(_ language: String) -> Bool {
        let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return code == "he" || code == "iw"
    }
}
