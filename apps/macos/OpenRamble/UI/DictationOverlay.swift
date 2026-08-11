import AppKit
import DictationCore
import SwiftUI

/// A small panel showing what's happening with dictation.
///
/// The panel does not take focus: the user dictates to another application, and the
/// focus would break the insert. Pay for this - VoiceOver does not get the panel itself
/// itself, so each state change is also announced out loud. This is not
/// decoration: the application does not have its own window, and there is no other way to find out what
/// the microphone is on, the blind person doesn’t have one either.
@MainActor
public final class DictationOverlay: OverlayPresenting {
    private var panel: NSPanel?
    private let model: OverlayModel
    /// Subscribe to change the panel size. The panel grows behind the content, and
    /// content changes during dictation.
    ///
    /// Marked `nonisolated(unsafe)` because the subscription is removed by `deinit`, and
    /// it is in an isolated class - outside of isolation. They only touch her from the main point
    /// stream: the panel lives entirely on it.
    nonisolated(unsafe) private var resizeObserver: (any NSObjectProtocol)?

    public init(
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        noticeDuration: Duration = .seconds(4),
        speedDuration: Duration = .seconds(2)
    ) {
        model = OverlayModel(
            announcer: announcer,
            noticeDuration: noticeDuration,
            speedDuration: speedDuration
        )
        model.onVisibilityChange = { [weak self] visible in
            if visible {
                self?.showPanel()
            } else {
                self?.hidePanel()
            }
        }
    }

    deinit {
        // A subscription left in the notification center survives the owner.
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }

    nonisolated public func present(_ state: DictationState, elapsed: TimeInterval) async {
        await MainActor.run { model.show(state, elapsed: elapsed) }
    }

    nonisolated public func dismiss() async {
        await MainActor.run { model.hide() }
    }

    nonisolated public func presentNotice(_ notice: DictationNotice) async {
        await MainActor.run { model.showNotice(notice) }
    }

    private func showPanel() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            // Dictation text should not leak into screen recordings via HUD.
            panel.sharingType = .none
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let hosting = NSHostingView(rootView: OverlayView(model: model))
            // The panel grows behind the content: a two-line message has no
            // the right to cut off to “automatic...” - a cut-off toast is worse than silence.
            hosting.sizingOptions = .preferredContentSize
            panel.contentView = hosting
            // The window keeps the upper left corner in place when resizing. Width
            // changes when the compact status turns into the recording waveform.
            // Without recalculation, she moved 80 points to the right of the center of the screen -
            // exactly at the moment when a person looks at her. We count by
            // the fact of the size change, and not just a guess about it: the size itself
            // sets SwiftUI, and it is not known here in advance.
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.position() }
            }
            self.panel = panel
        }
        position()
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    /// Show the panel on the screen where the user is currently working.
    ///
    /// The position is recalculated for each impression: during the time between dictations
    /// the monitor could be turned off or the mouse could move to another one.
    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 24
            )
        )
    }
}

/// State of the panel: what is written on it, whether it is visible and what has already been said out loud.
///
/// Lives separately from `NSPanel` intentionally. The window requires a graphics session, and
/// display rules - seconds counter, auto-hide message, advertisements for
/// VoiceOver - checked without it.
/// Recording-feedback edge: decoration on top of dictation, so separate protocol,
/// not a kernel extension. The fake overlay in tests records calls.
@MainActor
protocol RecordingFeedbackPresenting: AnyObject {
    func updateInputLevel(_ level: Float)
    func showSilenceHint()
}

/// The edge of the speed showcase is modeled after `RecordingFeedbackPresenting` and for the same reason:
/// This is a decoration on top of the dictation, not part of the kernel contract.
@MainActor
protocol SpeedPresenting: AnyObject {
    func showSpeed(_ readout: SpeedReadout)
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var notice: DictationNotice?
    static let waveformSampleCount = 48
    /// Recent microphone peaks (0...1), oldest first.
    @Published private(set) var waveformSamples = Array(
        repeating: Float(0),
        count: OverlayModel.waveformSampleCount
    )
    /// We listen for more than two seconds, but there is no signal: most likely, the wrong microphone.
    @Published private(set) var showsSilenceHint = false
    /// The line “stop → text: N ms” after successful insertion. Lives for a couple of seconds.
    @Published private(set) var speedLine: String?
    private var speedHide: Task<Void, Never>?

    /// Whether the panel should be on the screen. Shown by its owner.
    private(set) var isVisible = false
    var onVisibilityChange: ((Bool) -> Void)?

    /// Whether the seconds are counting down.
    var isTicking: Bool { timer != nil }

    var content: OverlayContent {
        OverlayContent.make(state: state, notice: notice, elapsed: elapsed)
    }

    private let announcer: any AccessibilityAnnouncing
    private let noticeDuration: Duration
    private let speedDuration: Duration
    /// Marked `nonisolated(unsafe)` because the timer removes `deinit`, and it has
    /// isolated class - outside of isolation. They touch him only from the main
    /// stream: the panel lives entirely on it.
    nonisolated(unsafe) private var timer: Timer?
    private var startedAt: Date?
    private var autoHide: Task<Void, Never>?
    /// What has already been said out loud. The seconds counter ticks twice per second, and without
    /// of this memory, VoiceOver would repeat “recording” until the end of the dictation.
    private var lastAnnouncement: String?

    init(
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        noticeDuration: Duration = .seconds(4),
        speedDuration: Duration = .seconds(2)
    ) {
        self.announcer = announcer
        self.noticeDuration = noticeDuration
        self.speedDuration = speedDuration
    }

    deinit {
        // The timer left in the run loop continues to wake up the process and
        // after the death of the owner.
        timer?.invalidate()
        autoHide?.cancel()
    }

    /// Show dictation status.
    func show(_ state: DictationState, elapsed: TimeInterval) {
        cancelAutoHide()
        self.state = state
        notice = nil
        // Once text is recognized, the destination application is the only
        // useful feedback surface. Do not cover it with a redundant insertion HUD.
        if state == .inserting {
            hide()
            return
        }
        if state == .listening {
            waveformSamples = Array(repeating: 0, count: Self.waveformSampleCount)
            showsSilenceHint = false
            // And the last number too: it’s about the last dictation.
            clearSpeed()
        }
        setElapsed(elapsed, ticking: state == .listening)
        setVisible(true)
        announceContent()
    }

    /// Panel shortcut for VoiceOver - along with a silent prompt if present.
    /// Panel shortcut for VoiceOver.
    ///
    /// Speed comes here - but not in ads. Number spoken out loud
    /// after each dictation, it would be intrusive; find it with the VoiceOver cursor,
    /// if you suddenly need it, no.
    var accessibilityLabel: String {
        var base = content.accessibilityLabel
        if showsSilenceHint { base = "\(Self.silenceHint) \(base)" }
        if let speedAccessibilityLabel { base = "\(base) \(speedAccessibilityLabel)" }
        return base
    }

    /// Verbal form of the speed string: "ms" is read by the synthesizer as "emes".
    private(set) var speedAccessibilityLabel: String?

    func updateInputLevel(_ level: Float) {
        guard state == .listening else { return }
        let sample = min(1, max(0, level))
        waveformSamples.removeFirst()
        waveformSamples.append(sample)
        if sample > 0.02 { showsSilenceHint = false }
    }

    /// There has been no signal for longer than the threshold - talk about the microphone.
    ///
    /// “The microphone can't hear you” is the most important thing for a blind person:
    /// they cannot see the flat waveform, and without an announcement learn about the
    /// dead microphone only by an empty result at the end.
    func showSilenceHint() {
        guard state == .listening, !showsSilenceHint else { return }
        showsSilenceHint = true
        announcer.announce(Self.silenceHint, urgent: true)
    }

    /// Tooltip text. One for the screen and for the announcement: they can’t leave.
    static let silenceHint = "No sound detected — check your microphone."

    /// Show the message and remove it after the specified time.
    func showNotice(_ notice: DictationNotice) {
        cancelAutoHide()
        // The error message is more important than the showcase: the number gives way to it.
        clearSpeed()
        setElapsed(elapsed, ticking: false)
        self.notice = notice
        setVisible(true)
        announceContent()

        let duration = noticeDuration
        autoHide = Task { [weak self] in
            try? await Task.sleep(for: duration)
            // Deferred hiding belongs to its show. Cancellation check
            // required: `try?` swallows it with and without an error
            // the canceled task does not finish sleeping, but wakes up immediately - and
            // removes the next message from the screen.
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
            self.setVisible(false)
        }
    }

    /// Show how long it took “let go → text in place.”
    ///
    /// Keeps the panel on the screen itself: `cleanup` calls `dismiss` via
    /// a few lines after the report, and without this the number would blink and disappear.
    func showSpeed(_ readout: SpeedReadout) {
        speedHide?.cancel()
        speedLine = readout.line
        speedAccessibilityLabel = readout.accessibilityLabel
        setVisible(true)
        let duration = speedDuration
        speedHide = Task { [weak self] in
            try? await Task.sleep(for: duration)
            // Cancellation check is required: `try?` swallows it along with the error,
            // and the canceled task would otherwise have taken away the next number.
            guard let self, !Task.isCancelled else { return }
            self.speedLine = nil
            self.setVisible(false)
        }
    }

    private func clearSpeed() {
        speedHide?.cancel()
        speedHide = nil
        speedLine = nil
        speedAccessibilityLabel = nil
    }

    /// Remove the panel.
    ///
    /// The message remains on the screen: the person must have time to read it, but
    /// cleanup after the session comes right after him. The same goes for the speed line:
    /// her showing comes from the same cleaning as the request to turn off the panel.
    func hide() {
        setElapsed(elapsed, ticking: false)
        guard notice == nil, speedLine == nil else { return }
        cancelAutoHide()
        setVisible(false)
        // The next dictation must appear again, even if the state
        // matches the previous one.
        lastAnnouncement = nil
    }

    /// Show elapsed time.
    ///
    /// While recording, the counter is still kept for VoiceOver even though the
    /// visible HUD is now only a waveform.
    private func setElapsed(_ value: TimeInterval, ticking: Bool) {
        elapsed = value

        guard ticking else {
            timer?.invalidate()
            timer = nil
            startedAt = nil
            return
        }

        guard timer == nil else { return }
        startedAt = Date().addingTimeInterval(-value)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// Delayed hiding of the past impression no longer works.
    private func cancelAutoHide() {
        autoHide?.cancel()
        autoHide = nil
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        onVisibilityChange?(visible)
    }

    private func announceContent() {
        let content = self.content
        guard let announcement = content.announcement, announcement != lastAnnouncement else { return }
        lastAnnouncement = announcement
        announcer.announce(announcement, urgent: content.isAnnouncementUrgent)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        let content = model.content

        return Group {
            if model.state == .listening, !model.showsSilenceHint {
                RecordingWaveform(samples: model.waveformSamples, color: .blue)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(color(for: content.tone))
                        .frame(width: 10, height: 10)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.showsSilenceHint ? OverlayModel.silenceHint : content.title)
                            .font(.system(size: 13, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle = content.subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let speedLine = model.speedLine {
                            Text(speedLine)
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(
            width: model.state == .listening || model.speedLine != nil ? 360 : 280,
            alignment: .leading
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        // The panel is read by one element: a colored dot and a counter
        //separately do not mean anything.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
    }

    private func color(for tone: OverlayContent.Tone) -> Color {
        switch tone {
        case .idle: return .secondary
        case .recording: return .red
        case .working: return .blue
        case .info: return .blue
        case .warning: return .orange
        case .failure: return .red
        }
    }
}


extension DictationOverlay: RecordingFeedbackPresenting {
    func updateInputLevel(_ level: Float) {
        model.updateInputLevel(level)
    }

    func showSilenceHint() {
        model.showSilenceHint()
    }
}

extension DictationOverlay: SpeedPresenting {
    func showSpeed(_ readout: SpeedReadout) {
        model.showSpeed(readout)
    }
}
