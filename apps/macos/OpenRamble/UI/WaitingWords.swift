import DictationCore
import Foundation

/// Words that could not land, waiting where the person works.
///
/// A paste can fail for reasons the person can fix in a second: another app
/// protects typing, or focus is not in a text field. The words stay on the
/// take block, in full, with the reason in plain words and one action bound to
/// the dictation key. Nothing sends the person to the menu bar.
///
/// A pure type: what the block says and what the key does are decided here and
/// checked by a state table, not by looking at the screen.
struct WaitingWords: Equatable {
    /// Why the paste did not land.
    enum Cause: Equatable {
        /// Secure input is on: a password field, or a terminal that protects
        /// typing. One system-wide state, so the app named is a best guess.
        case typingProtected(by: String?)
        /// Secure input went away while the words waited.
        case typingWorksAgain
        /// ⌘V was sent and nothing read it: focus is not in a text field.
        case noTextField
        /// Anything else. Trying the paste again is the whole answer.
        case notPasted

        /// The cause, from what the paste reported.
        init(_ failure: TextInsertionError?, protectedBy holder: String? = nil) {
            switch failure {
            case .secureInputActive: self = .typingProtected(by: holder)
            case .pasteNotRead: self = .noTextField
            default: self = .notPasted
            }
        }
    }

    /// What a tap of the dictation key does while these words wait.
    enum Action: Equatable {
        /// Our own ⌘V cannot land while typing is protected. The person's can,
        /// so the key copies and their ⌘V pastes.
        case copy
        case paste
    }

    /// The words, as they would have been pasted.
    var words: String
    var cause: Cause
    /// The words are on the clipboard and wait for the person's own ⌘V.
    var isCopied = false
    /// History could not keep this take, so the block is the only place the
    /// words are. Said on the block, and Later does not claim otherwise.
    var isKeptNowhereElse = false

    /// What else the person must know, or `nil`.
    var note: String? {
        isKeptNowhereElse ? L10n.tr("This dictation couldn't be saved to History.") : nil
    }

    var action: Action {
        if case .typingProtected = cause { return .copy }
        return .paste
    }

    var glyph: StateGlyph { isCopied ? .copied : .waiting }

    /// Why, in about eight words. `key` is the dictation key's short name.
    func reason(key: String) -> String {
        if isCopied { return L10n.tr("Copied. Press ⌘V to paste.") }
        switch cause {
        case let .typingProtected(holder?):
            return L10n.tr("Can't paste while %@ protects typing.", holder)
        case .typingProtected(nil):
            return L10n.tr("Can't paste while typing is protected.")
        case .typingWorksAgain:
            return L10n.tr("Typing works again.")
        case .noTextField:
            return L10n.tr("No text field. Click one, then tap %@.", Self.midSentence(key))
        case .notPasted:
            return L10n.tr("Not pasted.")
        }
    }

    /// The key's name inside a sentence. English keeps "Right ⌘"; Russian
    /// writes «правый ⌘», because a capital there reads as a new sentence.
    static func midSentence(_ key: String) -> String {
        guard L10n.shared.language == .russian, let first = key.first else { return key }
        return first.lowercased() + key.dropFirst()
    }

    /// What the key does, as the word beside its cap: "copies", "pastes".
    var actionVerb: String {
        switch action {
        case .copy: return L10n.tr("copies")
        case .paste: return L10n.tr("pastes")
        }
    }

    /// The whole block, for VoiceOver: state, reason, then what the key does.
    /// Never the words themselves: they would be read aloud to the room.
    func accessibilityLabel(keyName: String, key: String) -> String {
        if isCopied { return L10n.tr("Words waiting.") + " " + reason(key: key) }
        let job = action == .copy
            ? L10n.tr("%@ copies.", keyName)
            : L10n.tr("%@ pastes.", keyName)
        return [L10n.tr("Words waiting."), reason(key: key), job].joined(separator: " ")
    }
}

/// How a waiting take ended, said once on the block before it leaves.
enum TakeOutcome: Equatable {
    /// The words landed after waiting. `app` is where, when known.
    case pasted(into: String?)
    /// The words were put on the clipboard by the paste-last chord while
    /// typing was protected.
    case copied
    /// The person chose Later, or pressed Escape. `chord` is the paste-last
    /// shortcut, when one is set. `inHistory` is false for the rare take
    /// History could not keep: then the chord is the only way back.
    case kept(inHistory: Bool = true, chord: String?)

    var glyph: StateGlyph {
        switch self {
        case .pasted: return .pasted
        case .copied: return .copied
        case .kept: return .kept
        }
    }

    var message: String {
        switch self {
        case let .pasted(app?): return L10n.tr("Pasted into %@.", app)
        case .pasted(nil): return L10n.tr("Pasted.")
        case .copied: return L10n.tr("Copied. Press ⌘V to paste.")
        case let .kept(true, chord?): return L10n.tr("Kept in History. %@ pastes it.", chord)
        case .kept(true, nil): return L10n.tr("Kept in History.")
        case let .kept(false, chord?): return L10n.tr("%@ pastes it until you quit.", chord)
        case .kept(false, nil): return L10n.tr("The menu pastes it until you quit.")
        }
    }

    /// Long enough to read, short enough not to be in the way.
    var duration: Duration {
        switch self {
        case .pasted: return .milliseconds(700)
        case .copied: return .seconds(4)
        case .kept: return .seconds(3)
        }
    }
}

extension DictationHotkey {
    /// The key as it is drawn on a key cap: "Right ⌘".
    var shortTitle: String {
        switch self {
        case .fn: return "Fn"
        case .rightCommand: return L10n.tr("Right ⌘")
        case .rightOption: return L10n.tr("Right ⌥")
        case .leftControl: return L10n.tr("Left ⌃")
        case .leftCommand: return L10n.tr("Left ⌘")
        case .leftOption: return L10n.tr("Left ⌥")
        case .rightControl: return L10n.tr("Right ⌃")
        }
    }
}
