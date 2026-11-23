import AppIntents
import Foundation

// Intents the widget extension draws and the app performs.
//
// They live in this package, which the app and the extension both link
// statically, so the type is one and the same in both: the system then runs a
// Live Activity button's or a control's intent in the app, which is the process
// that holds the microphone. A copy compiled into each target would be two
// different types, and the system ran the extension's, which can do nothing.

/// What the intents do, supplied by the app when it launches. Empty in the
/// widget extension, which never performs them.
@MainActor
public enum IntentActions {
    /// Starts a take, or stops the one being recorded. Throws what went
    /// wrong, in words for the person.
    public static var dictate: (@MainActor () async throws -> Void)?
    /// Stops the take being recorded and writes it.
    public static var stop: (@MainActor () async -> Void)?
}

/// Starts a take, or stops the one being recorded. The Action button, Control
/// Center, the Lock Screen and Siri all reach it.
///
/// An `AudioRecordingIntent` may start the microphone with the app in the
/// background, on condition that a Live Activity shows the recording, which
/// the app starts with every take. It is a `LiveActivityIntent` as well, which
/// is what makes the system run it in the app rather than in the widget
/// extension that draws the control.
public struct DictateIntent: AudioRecordingIntent, LiveActivityIntent {
    public static let title: LocalizedStringResource = "Dictate"
    public static let description = IntentDescription(
        "Starts recording a take, or stops the one being recorded. The words are written on this iPhone and copied."
    )

    public init() {}

    /// A plain result: a control runs silently, and the Live Activity is
    /// what the person sees. A failure is thrown, and Siri or Shortcuts say it.
    @MainActor
    public func perform() async throws -> some IntentResult {
        try await IntentActions.dictate?()
        return .result()
    }
}

/// The Stop button in the Dynamic Island and on the Lock Screen.
public struct StopDictationIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop Recording"
    public static let description = IntentDescription("Stops the take and writes its words.")
    public static let isDiscoverable = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await IntentActions.stop?()
        return .result()
    }
}
