import AppKit
import Foundation
import Sparkle

/// Application updates.
///
/// Sparkle is the second and last place in the product that can go online.
/// Therefore, everything here is arranged so that she remains silent until she is asked.
///
/// Settings, without which the promise of “network only at your command” would be
/// not true, they are in Info.plist (see `apps/macos/project.yml`):
///
/// - `SUEnableAutomaticChecks = true` — the app looks for updates on its own.
/// The key is set explicitly rather than left absent: without it Sparkle asks
/// the person on the second launch, and a modal about update policy in the
/// first minute of a dictation app is a question nobody came here to answer.
/// This is the one place the app reaches the network without being asked,
/// and it is a deliberate trade — a security fix that never arrives helps
/// nobody. The switch is in Settings, and turning it off silences it fully.
/// - `SUSendProfileInfo = false` — a hardware report is not sent along with the request,
/// system version and language.
/// - `SUAllowsAutomaticUpdates = false` - no background downloading or installation
/// even as options: the update is installed only when clicked.
///
/// The two guarantees that do NOT depend on that switch: nothing about this
/// Mac travels with the request, and nothing installs by itself. Scheduled
/// checking is the only knob that changes the app's network behaviour.
@MainActor
public final class SparkleUpdater: ObservableObject {
    /// Is it possible to run the check right now. While another check is in progress or
    /// installation is not possible, and the menu item must be disabled.
    @Published public private(set) var canCheckForUpdates = false

    /// Sparkle did not start. This happens when the signature is configured incorrectly
    /// updates, and one cannot remain silent about this: people will think that
    /// updates come, but there are none.
    @Published public private(set) var startupFailure: String?

    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    public init() {
        // We start the mechanism ourselves, and not through `startingUpdater: true`. There
        // the configuration error turns into a Sparkle modal window, which
        // applications from the menu bar appears literally out of nowhere. We need
        // the same error, but in the settings and in your own words.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            // Sparkle only changes this property on the main thread.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }

        // We check the key ourselves before launching.
        //
        // Sparkle's own check is leaky here: with an HTTPS feed address and
        // in a signed application it misses the absence of an EdDSA key, writes
        // warning in the log and starts - then updates are checked
        // with just a code signature (`SPUUpdater.m`, branch `!hasAnyPublicKey`).
        // This is exactly the case that we will have at release, and errors when
        // does not occur. The promise of “updates signed with our key” is quiet
        // would weaken, and there would be nowhere to find out about it.
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let publicKey, !publicKey.isEmpty else {
            startupFailure = """
                This build has no public update-signing key (SUPublicEDKey). \
                Updates are disabled: without it there is no way to verify them.
                """
            return
        }

        do {
            // `start()` is `-[SPUUpdater startUpdater:]`, Swift cuts
            // from the name of the method the name of the type. Running doesn't download anything:
            // the check schedule is enabled only if the user himself
            // allowed auto-check.
            try controller.updater.start()
        } catch {
            startupFailure = error.localizedDescription
        }
    }

    /// Check for updates on a schedule (about once a day).
    ///
    /// The value is stored by Sparkle itself in the application settings. Your copy here
    /// you can’t start it: two truths about one switch sooner or later
    /// will disperse, and the application will start accessing the network despite the checkbox.
    public var automaticChecksEnabled: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            guard newValue != controller.updater.automaticallyChecksForUpdates else { return }
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Check for updates right now - at the user's command.
    public func checkForUpdates() {
        // The application lives in the menu bar and is never active. Without this window
        // Sparkle would open behind other people's windows, and the person would decide that
        // nothing happened.
        NSApplication.shared.activate()
        controller.updater.checkForUpdates()
    }
}
