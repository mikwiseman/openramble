import Foundation

/// How to handle text in a specific application.
///
/// In the terminal and code editor, a person dictates what should go into the file
/// verbatim. In a letter and chat - a phrase that you don’t mind tidying up.
public enum PromptMode: String, Sendable, Equatable, CaseIterable {
    /// Literally: minimal cosmetics, code inviolable.
    case verbatim
    /// Prose: processing is allowed that does not change the meaning.
    case prose
}

/// Category of the recipient application.
///
/// Nine categories - seed transferred from wai-computer. category, not
/// flat list bundle id, because that's how the person thinks:
/// “literally in terminals” - one solution, not twenty.
public enum ApplicationCategory: String, Sendable, Equatable, CaseIterable {
    case terminal
    case codeEditor
    case notes
    case messaging
    case mail
    case browser
    case design
    case office
    case unknown

    /// Default mode for the category.
    public var defaultMode: PromptMode {
        switch self {
        case .terminal, .codeEditor:
            return .verbatim
        case .notes, .messaging, .mail, .browser, .design, .office:
            return .prose
        case .unknown:
            // **Default of the unknown - verbatim.** An error in this direction will leave
            // extra word; an error in another will silently rewrite the command in the terminal,
            // which we just didn't recognize.
            return .verbatim
        }
    }
}

/// Deciding “which mode to apply to this application.”
///
/// Pure type with tests, as required by CLAUDE.md: this is policy, not logic
/// inside the view model. The only input is that the application already knows about
/// targets: bundle id and human readable name. Neither the screen nor the contents of the window,
/// no screenshots - only these two fields.
public struct PromptModePolicy: Sendable, Equatable {
    /// What the person chose with his hands: bundle id → mode. More important than the cards.
    public var overrides: [String: PromptMode]

    public init(overrides: [String: PromptMode] = [:]) {
        self.overrides = overrides
    }

    /// Precedent: person’s choice → category map → default.
    public func mode(for target: TargetApplication?) -> PromptMode {
        guard let target else { return ApplicationCategory.unknown.defaultMode }
        if let identifier = target.bundleIdentifier,
           let override = overrides[identifier.lowercased()] {
            return override
        }
        return Self.category(for: target).defaultMode
    }

    /// Target category. Public—the settings show it to the person.
    public static func category(for target: TargetApplication?) -> ApplicationCategory {
        guard let target else { return .unknown }
        if let identifier = target.bundleIdentifier?.lowercased(),
           let known = seed[identifier] {
            return known
        }
        // The name is the second attempt, not the first. Bundle id is stable, and name
        // localized and changed between versions; rely on him as
        // the main feature would be to change the mode depending on the system language.
        return categoryByName(target.localizedName)
    }

    /// Category seeds. The list is obviously incomplete - that’s why `.unknown` is used verbatim
    /// by default: the unfamiliar application gets safe mode rather than a guess.
    static let seed: [String: ApplicationCategory] = [
        // Terminals
        "com.apple.terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        "dev.warp.warp-stable": .terminal,
        "co.zeit.hyper": .terminal,
        "net.kovidgoyal.kitty": .terminal,
        "com.github.wez.wezterm": .terminal,
        "com.mitchellh.ghostty": .terminal,
        // Code editors
        "com.microsoft.vscode": .codeEditor,
        "com.microsoft.vscodeinsiders": .codeEditor,
        "com.todesktop.230313mzl4w4u92": .codeEditor,  // Cursor
        "com.apple.dt.xcode": .codeEditor,
        "com.jetbrains.intellij": .codeEditor,
        "com.jetbrains.pycharm": .codeEditor,
        "com.jetbrains.webstorm": .codeEditor,
        "com.sublimetext.4": .codeEditor,
        "dev.zed.zed": .codeEditor,
        "com.panic.nova": .codeEditor,
        // Notes
        "com.apple.notes": .notes,
        "notion.id": .notes,
        "md.obsidian": .notes,
        "com.agiletortoise.drafts-osx": .notes,
        "com.bear-writer": .notes,
        // Messengers
        "com.tinyspeck.slackmacgap": .messaging,
        "com.hnc.discord": .messaging,
        "ru.keepcoder.telegram": .messaging,
        "net.whatsapp.whatsapp": .messaging,
        "com.apple.messages": .messaging,
        "us.zoom.xos": .messaging,
        // Mail
        "com.apple.mail": .mail,
        "com.readdle.smartemail-mac": .mail,
        "com.superhuman.mail": .mail,
        // Browsers
        "com.apple.safari": .browser,
        "com.google.chrome": .browser,
        "org.mozilla.firefox": .browser,
        "company.thebrowser.browser": .browser,  // Arc
        "com.brave.browser": .browser,
        // Design
        "com.figma.desktop": .design,
        "com.bohemiancoding.sketch3": .design,
        "com.adobe.photoshop": .design,
        // Office
        "com.microsoft.word": .office,
        "com.apple.iwork.pages": .office,
        "com.microsoft.powerpoint": .office,
    ]

    private static func categoryByName(_ name: String?) -> ApplicationCategory {
        guard let name = name?.lowercased(), !name.isEmpty else { return .unknown }
        // Only those words that themselves mean a category. "Code"
        // not included here intentionally: too many things are called that way.
        if name.contains("terminal") || name.contains("console") { return .terminal }
        if name.contains("mail") { return .mail }
        return .unknown
    }
}
