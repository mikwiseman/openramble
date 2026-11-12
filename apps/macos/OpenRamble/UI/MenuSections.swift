import DictationCore

/// A row the menu can offer. `setupHints` expands to several controls in the
/// view; as policy it is one unit that appears and disappears whole.
enum MenuRow: Hashable {
    case statusLine
    case stopAndInsert
    case cancelDictation
    case setupHints
    case finishSetup
    /// One of the newest takes, by its first words: a click pastes it where
    /// the person is, and Option-click copies it. The first is the last take.
    /// Paste, Copy and Recent Dictations were three answers to one question;
    /// a short list of the words themselves is the one answer.
    case take(Int)
    case revealRecoveredRecordings
    case recordingLine
    case startRecording
    case startScreenRecording
    case pauseRecording
    case resumeRecording
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
/// - The newest takes lead the menu, the last one first, because the menu is
///   the backstop for words that could not land. Three at most: a menu is
///   not a history. Older takes live in the Library.
enum MenuSections {
    /// How many takes the menu offers. A menu is not a history.
    static let takeLimit = 3

    static func sections(
        state: DictationState,
        isDictationReady: Bool,
        wordsAreWaiting: Bool,
        recoveryStorageFaulted: Bool,
        takes: Int,
        recordingState: AppState.MeetingState = .idle
    ) -> [[MenuRow]] {
        var sections: [[MenuRow]] = []
        if state != .idle || recordingState == .idle || wordsAreWaiting {
            sections.append([.statusLine])
        }

        // A recording is orthogonal to a dictation — both can be true — so
        // its section comes first and stays whatever the session does. The
        // stop row is here because the window may be closed and the HUD
        // hidden; the menu is the one place that is always reachable.
        switch recordingState {
        case .idle: break
        case .starting, .stopping:
            sections.append([.recordingLine])
        case .recording:
            sections.append([.recordingLine, .pauseRecording, .stopRecording])
        case .paused:
            sections.append([.recordingLine, .resumeRecording, .stopRecording])
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
            if takes > 0 {
                sections.append((0..<min(takes, takeLimit)).map(MenuRow.take))
            }
            if recoveryStorageFaulted {
                sections.append([.revealRecoveredRecordings])
            }
            if recordingState == .idle {
                sections.append([.startRecording, .startScreenRecording])
            }
        }

        sections.append([.openRecordings, .settings, .quit])
        return sections
    }
}
