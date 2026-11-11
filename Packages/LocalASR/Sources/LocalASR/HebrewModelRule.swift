import Foundation

/// When the optional Hebrew model is offered, and when it recognizes a take.
///
/// The model the app ships hears 25 European languages and no Hebrew, and the
/// Hebrew model hears Hebrew only. A language setting would have to be changed
/// before every take by anyone who writes in two languages, so there is none:
/// a take is recognized in the language of the keyboard, which the person
/// already switches to type and which the menu bar already shows.
///
/// Settings offers the download to everyone, in one quiet row. It used to wait
/// for a Hebrew keyboard, and a person who wanted Hebrew looked for it in
/// Settings and found nothing. First-run setup still asks only where a Hebrew
/// keyboard says the person writes Hebrew, so nobody else is asked about a
/// language while setting up.
public struct HebrewModelRule: Sendable, Equatable {
    /// First-run setup shows the download: this Mac has a Hebrew keyboard, or
    /// something of the model is already on disk.
    public let isOfferedInSetup: Bool
    /// This Mac can switch to a Hebrew keyboard, which is what turns the
    /// model on. Without one the model is downloaded and never used, so the
    /// card says how to add it.
    public let hasKeyboard: Bool
    /// The next take is recognized with the Hebrew model.
    public let recognizes: Bool

    /// - Parameters:
    ///   - keyboardLanguage: the language of the keyboard in use now.
    ///   - enabledKeyboardLanguages: the languages of every keyboard this Mac
    ///     can switch to.
    ///   - model: what the disk holds of the Hebrew model.
    public init(keyboardLanguage: String?, enabledKeyboardLanguages: [String], model: ModelState) {
        hasKeyboard = enabledKeyboardLanguages.contains(where: Self.isHebrew)
        isOfferedInSetup = hasKeyboard || model != .notInstalled
        recognizes = model.isReady && keyboardLanguage.map(Self.isHebrew) == true
    }

    /// Hebrew is "he", with or without a region, and "iw" in older data.
    static func isHebrew(_ language: String) -> Bool {
        let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return code == "he" || code == "iw"
    }
}
