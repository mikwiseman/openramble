import AppIntents
import Foundation
import UniformTypeIdentifiers

/// What the shared intents do inside the app.
@MainActor
enum IntentBridge {
    static func dictate() async -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        if app.dictation.isRecording {
            await app.dictation.finish()
            return .result(dialog: "Writing your words.")
        }
        guard await app.waitUntilReady() else {
            return .result(dialog: "Open OpenRamble once to download its voice model.")
        }
        guard MicrophoneRecorder.permission == .granted else {
            return .result(dialog: "Open OpenRamble once to allow the microphone.")
        }
        await app.dictation.start()
        return .result(dialog: app.dictation.isRecording ? "Listening." : "The microphone did not start.")
    }

    static func stop() async {
        await AppModel.shared.dictation.finish()
    }
}

/// Writes the words spoken in an audio file: a voice memo, a message, a
/// lecture. The file becomes a take in the app too.
struct TranscribeAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Write Audio as Text"
    static let description = IntentDescription(
        "Writes the words spoken in an audio file, on this iPhone. The file is kept as a take in OpenRamble."
    )

    @Parameter(title: "Audio", supportedContentTypes: [.audio])
    var audio: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = AppModel.shared
        guard await app.waitUntilReady() else {
            throw IntentFailure.modelMissing
        }
        let name = audio.filename.isEmpty ? "audio.m4a" : audio.filename
        let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
        try audio.data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let take = await app.dictation.open(file: file) else { throw IntentFailure.unreadable }
        switch take.state {
        case .written, .silent:
            return .result(value: take.text)
        case let .failed(reason):
            throw IntentFailure.failed(reason)
        case .writing:
            throw IntentFailure.failed("The words were not written.")
        }
    }
}

/// The newest take's words, for a shortcut to do something with.
struct LatestTakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Take"
    static let description = IntentDescription("The words of your most recent take.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let take = AppModel.shared.dictation.store.latestWritten else {
            throw IntentFailure.noTakes
        }
        return .result(value: take.text)
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case modelMissing
    case unreadable
    case noTakes
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .modelMissing: "Open OpenRamble once to download its voice model."
        case .unreadable: "That audio could not be read."
        case .noTakes: "There are no takes yet."
        case let .failed(reason): "\(reason)"
        }
    }
}

struct OpenRambleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: ["Dictate with \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Dictate",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: TranscribeAudioIntent(),
            phrases: ["Write audio as text with \(.applicationName)"],
            shortTitle: "Write Audio as Text",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: LatestTakeIntent(),
            phrases: ["Get my latest \(.applicationName) take"],
            shortTitle: "Latest Take",
            systemImageName: "text.quote"
        )
    }
}
