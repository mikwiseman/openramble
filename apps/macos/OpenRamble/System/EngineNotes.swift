import Foundation
import os

/// The engine's own notes about loading, unloading and warming.
///
/// These have always been written, at `info` level — which macOS keeps in a
/// memory ring and discards, so they exist only for whoever is watching with
/// `log show --info` at the time. That is the wrong way round: the moment you
/// want them is after a slow dictation you did not expect.
///
/// Turning on detailed logging writes them at `notice` instead, where the
/// system persists them. Nothing new is measured and nothing is written that
/// was not already being written — only the level changes, which is the whole
/// difference between a note that survives and one that does not.
///
/// Never carries dictated text. Numbers and reasons only, like everything else
/// this app logs.
enum EngineNotes {
    /// Set from the setting. Read on every note, so the switch takes effect
    /// immediately rather than at the next launch.
    nonisolated(unsafe) static var isDetailed = SettingsDefaults.detailedLogging

    static func note(_ message: String) {
        if isDetailed {
            engineLog.notice("\(message, privacy: .public)")
        } else {
            engineLog.info("\(message, privacy: .public)")
        }
    }
}
