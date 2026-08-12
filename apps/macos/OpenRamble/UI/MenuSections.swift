import DictationCore

/// A row the menu can offer. `setupHints` expands to several controls in the
/// view; as policy it is one unit that appears and disappears whole.
enum MenuRow: Equatable {
    case statusLine
    case stopAndInsert
    case cancelDictation
    case setupHints
    case finishSetup
    case insertLastDictation
    case recentDictations
    case copyLastAsSpoken
    case settings
    case quit
}

/// Which rows the menu offers in each state — as data, so the whole matrix is
/// testable without rendering a menu.
///
/// The shape of the answer is sections: the view joins them with dividers.
/// Design rules the matrix encodes:
/// - While a session runs, the menu is about the session. Nothing else can be
///   acted on anyway, and a short menu is read faster mid-dictation.
/// - Transcribing is seconds and cannot be meaningfully cancelled from a menu
///   that takes longer to open; Escape still works.
/// - At most ONE recovery row ever appears: "Insert Last Dictation". Failed
///   transcription recordings heal quietly (kept on disk briefly, pruned by
///   age) instead of demanding menu decisions — the strange
///   "Transcribe/Delete Saved Recording" pair is gone by design; do not
///   re-add it.
enum MenuSections {
    static func sections(
        state: DictationState,
        isDictationReady: Bool,
        hasRecoveredText: Bool,
        hasRecents: Bool,
        canCopyAsSpoken: Bool
    ) -> [[MenuRow]] {
        var sections: [[MenuRow]] = [[.statusLine]]

        switch state {
        case .preparing, .listening:
            sections.append([.stopAndInsert, .cancelDictation])
        case .transcribing, .inserting:
            break
        case .idle:
            if !isDictationReady {
                sections.append([.setupHints, .finishSetup])
            }
            if hasRecoveredText {
                sections.append([.insertLastDictation])
            }
            var history: [MenuRow] = []
            if hasRecents { history.append(.recentDictations) }
            if canCopyAsSpoken { history.append(.copyLastAsSpoken) }
            if !history.isEmpty { sections.append(history) }
        }

        sections.append([.settings, .quit])
        return sections
    }
}
