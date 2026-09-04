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
    case revealRecoveredRecordings
    case recentDictations
    case copyLast
    case recordingLine
    case startRecording
    case stopRecording
    case openRecordings
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
/// - Recognized text recovery and retained audio are different promises. Text
///   can be retried in place; audio is announced by the failure notice the
///   moment it is kept and lives behind a Settings row afterwards. The menu
///   itself stays about dictation — a permanent "Recovered Recordings (2)…"
///   row read as unexplained debris, not as care. The single exception is a
///   recovery-storage fault: when safe cleanup cannot be persisted, hiding
///   retained voice data would break the privacy promise, so that state keeps
///   its menu row until it is resolved.
enum MenuSections {
    static func sections(
        state: DictationState,
        isDictationReady: Bool,
        hasRecoveredText: Bool,
        recoveryStorageFaulted: Bool,
        hasRecents: Bool,
        isRecording: Bool = false
    ) -> [[MenuRow]] {
        var sections: [[MenuRow]] = [[.statusLine]]

        // A recording is orthogonal to a dictation — both can be true — so
        // its section comes first and stays whatever the session does. The
        // stop row is here because the window may be closed and the HUD
        // hidden; the menu is the one place that is always reachable.
        if isRecording {
            sections.append([.recordingLine, .stopRecording])
        }

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
            if recoveryStorageFaulted {
                sections.append([.revealRecoveredRecordings])
            }
            if hasRecents {
                sections.append([.recentDictations, .copyLast])
            }
            if !isRecording {
                sections.append([.startRecording])
            }
        }

        sections.append([.openRecordings, .settings, .quit])
        return sections
    }
}
