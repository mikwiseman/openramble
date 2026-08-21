import AppKit
import DictationCore
import SwiftUI

private final class OverlayCommandOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var latestSession: DictationSessionID?
    private var lastAppliedRevision: UInt64 = 0

    func advance(to session: DictationSessionID) {
        lock.lock()
        defer { lock.unlock() }
        guard latestSession.map({ session >= $0 }) ?? true else { return }
        if latestSession != session {
            latestSession = session
            lastAppliedRevision = 0
        }
    }

    func accepts(session: DictationSessionID, revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard latestSession == session, revision >= lastAppliedRevision else { return false }
        lastAppliedRevision = revision
        return true
    }
}

/// A panel that can say it is waiting for the model rather than working.
///
/// Separate from `OverlayPresenting` on purpose: this is not a session command
/// and must not travel through the ordering fence, where a queued state
/// command could overwrite it or a wedged window server could hold it.
@MainActor
public protocol EngineWaitPresenting: AnyObject {
    func setWaitingForEngine(_ waiting: Bool)
}

/// A small panel showing what's happening with dictation.
///
/// The panel does not take focus: the user dictates to another application, and the
/// focus would break the insert. Pay for this - VoiceOver does not get the panel itself
/// itself, so each state change is also announced out loud. This is not
/// decoration: the application does not have its own window, and there is no other way to find out what
/// the microphone is on, the blind person doesn’t have one either.
@MainActor
public final class DictationOverlay: OverlayPresenting, EngineWaitPresenting {
    private var panel: NSPanel?
    private let model: OverlayModel
    /// Synchronous issue-order fence shared with nonisolated protocol calls.
    private nonisolated let commandOrder = OverlayCommandOrder()
    /// Subscribe to change the panel size. The panel grows behind the content, and
    /// content changes during dictation.
    ///
    /// Marked `nonisolated(unsafe)` because the subscription is removed by `deinit`, and
    /// it is in an isolated class - outside of isolation. They only touch her from the main point
    /// stream: the panel lives entirely on it.
    nonisolated(unsafe) private var resizeObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var screenObserver: (any NSObjectProtocol)?

    var placement: DictationOverlayPlacement = .top {
        didSet {
            guard oldValue != placement, panel?.isVisible == true else { return }
            position()
        }
    }

    public init(
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        noticeDuration: Duration = .seconds(4)
    ) {
        model = OverlayModel(
            announcer: announcer,
            noticeDuration: noticeDuration
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
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    nonisolated public func present(_ state: DictationState, elapsed: TimeInterval) async {
        await MainActor.run { model.show(state, elapsed: elapsed) }
    }

    nonisolated public func dismiss() async {
        await MainActor.run { model.hide() }
    }

    @MainActor
    public func setWaitingForEngine(_ waiting: Bool) {
        model.setWaitingForEngine(waiting)
    }

    nonisolated public func presentNotice(_ notice: DictationNotice) async {
        await MainActor.run { model.showNotice(notice) }
    }

    nonisolated public func present(
        _ state: DictationState,
        elapsed: TimeInterval,
        session: DictationSessionID
    ) async {
        advance(to: session, revision: 0)
        await present(state, elapsed: elapsed, session: session, revision: 0)
    }

    nonisolated public func dismiss(session: DictationSessionID) async {
        advance(to: session, revision: 0)
        await dismiss(session: session, revision: 0)
    }

    nonisolated public func presentNotice(
        _ notice: DictationNotice,
        session: DictationSessionID
    ) async {
        advance(to: session, revision: 0)
        await presentNotice(notice, session: session, revision: 0)
    }

    nonisolated public func advance(to session: DictationSessionID, revision: UInt64) {
        commandOrder.advance(to: session)
    }

    nonisolated public func present(
        _ state: DictationState,
        elapsed: TimeInterval,
        session: DictationSessionID,
        revision: UInt64
    ) async {
        await MainActor.run {
            guard commandOrder.accepts(session: session, revision: revision) else { return }
            model.show(state, elapsed: elapsed)
        }
    }

    nonisolated public func dismiss(
        session: DictationSessionID,
        revision: UInt64
    ) async {
        await MainActor.run {
            guard commandOrder.accepts(session: session, revision: revision) else { return }
            model.hide()
        }
    }

    nonisolated public func presentNotice(
        _ notice: DictationNotice,
        session: DictationSessionID,
        revision: UInt64
    ) async {
        await MainActor.run {
            guard commandOrder.accepts(session: session, revision: revision) else { return }
            model.showNotice(notice)
        }
    }

    private func showPanel() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 244, height: 52),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            // Capturable on purpose, and this was once the other way round.
            //
            // The panel was excluded from screen capture to keep dictated text
            // out of recordings — but it never shows dictated text: there is no
            // live preview, only the state and, when something fails, the
            // message about it. What the exclusion actually did was make those
            // failure messages unscreenshottable: a person hitting an error
            // could not send a picture of it, and macOS answered their attempt
            // with "Unable to capture window image". It also erased the panel
            // from every demo and screen share of the app.
            //
            // If a live preview is ever added, this decision must be revisited
            // in the same commit.
            panel.sharingType = .readOnly
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            // The HUD is status feedback, not a control. It must never eat a click
            // intended for the application underneath it.
            panel.ignoresMouseEvents = true
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
            // A Dock move, display reconnect or resolution change can alter
            // `visibleFrame` without resizing this panel.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
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
            OverlayPlacementPolicy.origin(
                placement: placement,
                visibleFrame: frame,
                panelSize: size
            )
        )
    }
}

extension DictationOverlay: OverlayPlacementConfiguring {}

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
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var notice: DictationNotice?
    /// Exactly as many samples as the waveform draws: publishing more would
    /// mean half the buffer is never shown.
    static let waveformSampleCount = 24
    /// Recent microphone peaks (0...1), oldest first.
    @Published private(set) var waveformSamples = Array(
        repeating: Float(0),
        count: OverlayModel.waveformSampleCount
    )
    /// Whether the panel should be on the screen. Shown by its owner.
    @Published private(set) var isVisible = false
    var onVisibilityChange: ((Bool) -> Void)?

    /// Whether the seconds are counting down.
    var isTicking: Bool { timer != nil }

    /// Whether the finished take is waiting for a model load rather than for
    /// recognition. Only the transcribing panel reads it.
    @Published private(set) var isWaitingForEngine = false

    var content: OverlayContent {
        OverlayContent.make(
            state: state,
            notice: notice,
            elapsed: elapsed,
            isWaitingForEngine: isWaitingForEngine
        )
    }

    /// What the panel draws, or `nil` while its window is off screen.
    ///
    /// AppKit ordering the panel out does not remove its retained SwiftUI tree.
    /// Keeping the visibility check here prevents an off-screen view from
    /// continuing a symbol effect, progress indicator, or glass composition.
    var visibleContent: OverlayContent? { isVisible ? content : nil }

    private let announcer: any AccessibilityAnnouncing
    private let noticeDuration: Duration
    /// Marked `nonisolated(unsafe)` because the timer removes `deinit`, and it has
    /// isolated class - outside of isolation. They touch him only from the main
    /// stream: the panel lives entirely on it.
    nonisolated(unsafe) private var timer: Timer?
    private var startedAt: Date?
    private var autoHide: Task<Void, Never>?
    /// A session may finish while a notice owns the panel. Preserve the notice
    /// long enough to be read, then honor that deferred dismissal.
    private var dismissAfterNotice = false
    /// What has already been said out loud. The seconds counter ticks twice per second, and without
    /// of this memory, VoiceOver would repeat “recording” until the end of the dictation.
    private var lastAnnouncement: String?

    init(
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        noticeDuration: Duration = .seconds(4)
    ) {
        self.announcer = announcer
        self.noticeDuration = noticeDuration
    }

    deinit {
        // The timer left in the run loop continues to wake up the process and
        // after the death of the owner.
        timer?.invalidate()
        autoHide?.cancel()
    }

    /// The take is waiting for a model that is still loading.
    func setWaitingForEngine(_ waiting: Bool) {
        guard isWaitingForEngine != waiting else { return }
        isWaitingForEngine = waiting
        // The panel is already on screen showing the transcribing state; this
        // only changes what it says. Re-announcing lets VoiceOver hear the
        // difference between waiting and working, which is the whole point.
        guard state == .transcribing, notice == nil, isVisible else { return }
        announceContent()
    }

    /// Show dictation status.
    func show(_ state: DictationState, elapsed: TimeInterval) {
        cancelAutoHide()
        dismissAfterNotice = false
        // A wait belongs to exactly one take. Leaving the flag set would let a
        // finished load narrate the next dictation.
        if state != .transcribing { isWaitingForEngine = false }
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
        }
        setElapsed(elapsed, ticking: state == .listening)
        setVisible(true)
        announceContent()
    }

    /// Panel shortcut for VoiceOver.
    var accessibilityLabel: String { content.accessibilityLabel }

    func updateInputLevel(_ level: Float) {
        guard state == .listening else { return }
        let sample = min(1, max(0, level))
        waveformSamples.removeFirst()
        waveformSamples.append(sample)
    }

    /// Show the message and remove it after the specified time.
    func showNotice(_ notice: DictationNotice) {
        cancelAutoHide()
        // Keep the recording clock alive behind a transient notice. The notice
        // does not display elapsed time, but returning to the HUD must not lose
        // the seconds during which it was visible.
        setElapsed(elapsed, ticking: state == .listening)
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
            // The same warning in a later session is new information. Keep
            // de-duplication only for repeated updates within one impression.
            self.lastAnnouncement = nil
            if self.dismissAfterNotice {
                self.finishHiding()
                return
            }
            switch self.state {
            case .preparing, .listening, .transcribing:
                // An unrelated menu action can show a notice while the microphone
                // keeps running. Return to the underlying session instead of
                // silently removing its HUD and elapsed timer.
                self.setElapsed(self.elapsed, ticking: self.state == .listening)
                self.setVisible(true)
                self.announceContent()
            case .idle, .inserting:
                self.setVisible(false)
            }
        }
    }

    /// Remove the panel.
    ///
    /// The message remains on the screen: the person must have time to read it, but
    /// cleanup after the session comes right after it.
    func hide() {
        setElapsed(elapsed, ticking: false)
        guard notice == nil else {
            dismissAfterNotice = true
            return
        }
        cancelAutoHide()
        finishHiding()
    }

    private func finishHiding() {
        // Commit the finished state before the visibility callback enters
        // AppKit. A hidden hosting view must not keep describing live work.
        dismissAfterNotice = false
        state = .idle
        isWaitingForEngine = false
        setVisible(false)
        // The next dictation must appear again, even if the state
        // matches the previous one.
        lastAnnouncement = nil
    }

    /// Show elapsed time.
    ///
    /// While recording, the counter drives both the visible duration and the
    /// VoiceOver label without requiring a redraw loop in the menu bar.
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
        if let content = model.visibleContent {
            panel(content)
        } else {
            // Preserve the panel's initial preferred size for placement while
            // removing every animated and composited child from the retained
            // host view. In bottom placement, collapsing the height would put
            // the first expanded frame below the visible screen.
            Color.clear.frame(width: preferredWidth, height: 52)
        }
    }

    private func panel(_ content: OverlayContent) -> some View {
        HStack(spacing: 10) {
            if model.notice != nil {
                Image(systemName: content.tone.iconName)
                    .foregroundStyle(toneColor(content.tone))
                    .font(.body.weight(.semibold))
                Text(content.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.state == .listening {
                Circle()
                    .fill(StatusColorRole.recording.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                RecordingWaveform(
                    samples: model.waveformSamples,
                    color: StatusColorRole.recording.color
                )
                .frame(width: 136, height: 28)
                Text(elapsedText)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if model.state == .transcribing {
                // The same blue as the menu bar dot: one color for "working
                // on speech" everywhere. Keep the symbol static: this panel is
                // visible while the recognition result waits for the main actor,
                // and an iterative symbol effect drove a RenderBox/CA commit on
                // every display refresh through the glass surface.
                Image(systemName: "waveform")
                    .foregroundStyle(StatusColorRole.processing.color)
                    .font(.body.weight(.semibold))
                    .accessibilityHidden(true)
                Text(content.title)
                    .font(.callout.weight(.medium))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(content.title)
                    .font(.callout.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(
            width: preferredWidth,
            alignment: .leading
        )
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // The panel is read by one element: a colored dot and a counter
        //separately do not mean anything.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
    }

    private var preferredWidth: CGFloat {
        if model.notice != nil { return 320 }
        if model.state == .listening { return 244 }
        return 220
    }

    private var elapsedText: String {
        let total = Int(max(0, model.elapsed).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func toneColor(_ tone: OverlayContent.Tone) -> Color {
        tone.colorRole?.color ?? .secondary
    }
}


extension DictationOverlay: RecordingFeedbackPresenting {
    func updateInputLevel(_ level: Float) {
        model.updateInputLevel(level)
    }
}
