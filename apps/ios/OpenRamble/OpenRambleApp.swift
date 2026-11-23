import SwiftUI
import UIKit

@main
struct OpenRambleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app.setup)
                .environment(app.dictation)
                .environment(app.dictation.store)
                // An audio file opened in OpenRamble from Files or a share sheet.
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task { await app.dictation.open(file: url) }
                }
        }
    }
}

/// The objects the whole app shares, the App Intents included.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let setup: ModelSetup
    let dictation: Dictation

    private init() {
        setup = ModelSetup.standard()
        dictation = Dictation(store: TakeStore.standard(), writer: Writer(), recorder: Self.recorder())
        // Not tied to a view: an intent can launch the app with no window.
        setup.start { [dictation] phase in
            await Self.follow(phase, dictation: dictation)
        }
        #if DEBUG
        setup.importFromLaunchArguments()
        #endif
    }

    /// Waits a few seconds for the model to open, for an intent that arrived
    /// as the app launched. False if there is no model to open.
    func waitUntilReady() async -> Bool {
        for _ in 0..<200 {
            if dictation.isModelOpen { return true }
            switch setup.phase {
            case .absent, .failed, .downloading, .removing: return false
            default: try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return dictation.isModelOpen
    }

    private static func recorder() -> any VoiceRecording {
        #if DEBUG
        if let replay = ReplayRecorder.fromLaunchArguments() { return replay }
        #endif
        return MicrophoneRecorder()
    }

    /// The model is opened whenever it becomes ready and closed when removed.
    private static func follow(_ phase: ModelSetup.Phase, dictation: Dictation) async {
        switch phase {
        case let .ready(directory):
            await dictation.modelBecameReady(at: directory)
        case .absent, .removing:
            if dictation.isModelOpen { await dictation.modelWasRemoved() }
        default:
            break
        }
    }
}

/// Receives what UIKit hands the app outside SwiftUI; the model download's
/// background events are handled beside the download, in ModelDownload.swift.
final class AppDelegate: NSObject, UIApplicationDelegate {}
