import AppIntents
import Foundation

// Intents the widget extension draws and the app performs. Each type is
// compiled into both, because a control or a Live Activity button can only
// name an intent its own process knows; the system runs these in the app.

/// Starts a take, or stops the one being recorded. The Action button, Control
/// Center, the Lock Screen and Siri all reach it.
///
/// An `AudioRecordingIntent` may start the microphone with the app in the
/// background, on condition that a Live Activity shows the recording, which
/// `Dictation` starts with every take.
struct DictateIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Dictate"
    static let description = IntentDescription(
        "Starts recording a take, or stops the one being recorded. The words are written on this iPhone and copied."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "")
        #else
        return await IntentBridge.dictate()
        #endif
    }
}

/// The Stop button in the Dynamic Island and on the Lock Screen.
struct StopDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the take and writes its words.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await IntentBridge.stop()
        #endif
        return .result()
    }
}
