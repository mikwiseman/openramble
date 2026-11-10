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

/// A panel that can say the microphone stays live after the key is let go.
///
/// Outside the session fence for the same reason as `EngineWaitPresenting`:
/// it changes what the current panel shows, not which session owns it.
@MainActor
public protocol HandsFreePresenting: AnyObject {
    /// The key that finishes the take, or `nil` once it is no longer hands-free.
    func setHandsFree(finishKey: String?)
}

/// A block that can hold words that could not land, and say how that ended.
///
/// Outside the session fence like the two protocols above: the application
/// owns the waiting words, and they outlive the session that produced them.
@MainActor
protocol WaitingWordsPresenting: AnyObject {
    /// A tap of the key, or a click on the block's first button.
    var onWaitingAction: (() -> Void)? { get set }
    /// Later, on the block.
    var onWaitingLater: (() -> Void)? { get set }
    /// The words that wait, or `nil` once they no longer do.
    func setWaiting(_ waiting: WaitingWords?, key: DictationHotkey)
    func showOutcome(_ outcome: TakeOutcome)
    /// The real key went down or came up: the drawn one follows.
    func setKeyDown(_ down: Bool)
}

/// A small panel showing what's happening with dictation.
///
/// The panel does not take focus: the user dictates to another application, and the
/// focus would break the insert. Pay for this - VoiceOver does not get the panel itself
/// itself, so each state change is also announced out loud. This is not
/// decoration: the application does not have its own window, and there is no other way to find out what
/// the microphone is on, the blind person doesn’t have one either.
@MainActor
public final class DictationOverlay: OverlayPresenting, EngineWaitPresenting, HandsFreePresenting {
    private var panel: NSPanel?
    private let model: OverlayModel
    var onWaitingAction: (() -> Void)? {
        get { model.onWaitingAction }
        set { model.onWaitingAction = newValue }
    }
    var onWaitingLater: (() -> Void)? {
        get { model.onWaitingLater }
        set { model.onWaitingLater = newValue }
    }
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
        model.onWordsShownChange = { [weak self] in self?.applyWordsMode() }
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

    @MainActor
    public func setHandsFree(finishKey: String?) {
        model.setHandsFree(finishKey: finishKey)
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
                contentRect: NSRect(x: 0, y: 0, width: 244, height: GlassTokens.Block.unit),
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
            // Revisited, as promised: the block now shows dictated words
            // while they wait, and for exactly that long it leaves captures.
            // See `applyWordsMode`.
            panel.sharingType = .readOnly
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            // The HUD is status feedback, not a control. It must never eat a click
            // intended for the application underneath it.
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = Self.makeContentView(model: model)
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
        applyWordsMode()
        position()
        panel?.orderFrontRegardless()
    }

    /// The block is status feedback and never eats a click, with one
    /// exception: while it holds words it is the thing to press. A
    /// non-activating panel takes that click without becoming key, so the app
    /// the words are meant for keeps the focus the paste needs.
    ///
    /// For the same stretch the block shows what the person said, so it is
    /// kept out of screenshots, recordings and screen shares.
    private func applyWordsMode() {
        let showsWords = model.waiting != nil
        panel?.ignoresMouseEvents = !showsWords
        panel?.sharingType = showsWords ? .none : .readOnly
    }

    /// The view the panel is sized by.
    ///
    /// The panel grows with its content: waiting words are shown in full,
    /// and a cut-off block is worse than silence.
    ///
    /// The size comes from constraints, not from `.preferredContentSize`. On
    /// macOS 27 that option alone leaves a content view's window at the size
    /// it was created with, so a 384-point block was drawn into a 244-point
    /// panel and clipped on both sides. With these three the hosting view
    /// states its content's size as constraints, and the window follows them.
    static func makeContentView(model: OverlayModel) -> NSView {
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        return hosting
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

extension DictationOverlay: WaitingWordsPresenting {
    func setWaiting(_ waiting: WaitingWords?, key: DictationHotkey) {
        model.key = key
        model.setWaiting(waiting)
    }

    func showOutcome(_ outcome: TakeOutcome) {
        model.showOutcome(outcome)
    }

    func setKeyDown(_ down: Bool) {
        model.isKeyDown = down
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

    /// The current state has outlasted `OverlayContent.titleDelay` and may
    /// now say what it is.
    @Published private(set) var hasLingered = false

    /// The key that finishes a hands-free take, while one runs.
    @Published private(set) var handsFreeFinishKey: String?

    /// Words that could not land. The application owns them; the block only
    /// shows them.
    @Published private(set) var waiting: WaitingWords? {
        didSet {
            guard (oldValue == nil) != (waiting == nil) else { return }
            onWordsShownChange?()
        }
    }
    /// How a waiting take just ended.
    @Published private(set) var outcome: TakeOutcome?
    /// The dictation key, as the block draws and names it.
    @Published var key: DictationHotkey = SettingsDefaults.hotkey
    /// Whether the real key is down: the drawn one goes down with it.
    @Published var isKeyDown = false
    var onWaitingAction: (() -> Void)?
    var onWaitingLater: (() -> Void)?
    /// The block started or stopped showing dictated words.
    var onWordsShownChange: (() -> Void)?

    var content: OverlayContent {
        OverlayContent.make(
            state: state,
            notice: notice,
            elapsed: elapsed,
            isWaitingForEngine: isWaitingForEngine,
            hasLingered: hasLingered,
            handsFreeFinishKey: handsFreeFinishKey,
            waiting: waiting,
            outcome: outcome,
            key: key
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
    private let titleDelay: Duration
    private var reveal: Task<Void, Never>?
    /// Marked `nonisolated(unsafe)` because the timer removes `deinit`, and it has
    /// isolated class - outside of isolation. They touch him only from the main
    /// stream: the panel lives entirely on it.
    nonisolated(unsafe) private var timer: Timer?
    private var startedAt: Date?
    private var autoHide: Task<Void, Never>?
    private var outcomeHide: Task<Void, Never>?
    /// A fixed time for every outcome, so a test need not wait out the real ones.
    private let outcomeDuration: Duration?
    /// A session may finish while a notice owns the panel. Preserve the notice
    /// long enough to be read, then honor that deferred dismissal.
    private var dismissAfterNotice = false
    /// What has already been said out loud. The seconds counter ticks twice per second, and without
    /// of this memory, VoiceOver would repeat the same words until the end of the dictation.
    private var lastAnnouncement: String?
    /// The microphone-open tone belongs to the take, not to each redraw or
    /// each return from a notice.
    private var hasCuedThisTake = false
    /// Going hands-free is the one other moment worth a tone: the key is up
    /// and the microphone stays live.
    private var hasCuedHandsFree = false

    init(
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        noticeDuration: Duration = .seconds(4),
        titleDelay: Duration = OverlayContent.titleDelay,
        outcomeDuration: Duration? = nil
    ) {
        self.announcer = announcer
        self.noticeDuration = noticeDuration
        self.titleDelay = titleDelay
        self.outcomeDuration = outcomeDuration
    }

    deinit {
        // The timer left in the run loop continues to wake up the process and
        // after the death of the owner.
        timer?.invalidate()
        autoHide?.cancel()
        outcomeHide?.cancel()
        reveal?.cancel()
    }

    /// Nothing but waiting words or their outcome keeps the block up at rest.
    private var restsVisible: Bool { waiting != nil || outcome != nil }

    /// The words that wait, or `nil` once they no longer do.
    func setWaiting(_ waiting: WaitingWords?) {
        guard self.waiting != waiting else { return }
        self.waiting = waiting
        guard waiting != nil else {
            if isAtRest, notice == nil { setVisible(restsVisible) }
            return
        }
        // The block is the answer now; whatever it said a moment ago is not.
        clearOutcome()
        cancelAutoHide()
        notice = nil
        dismissAfterNotice = false
        setVisible(true)
        announceContent()
    }

    /// Say how a waiting take ended, then leave.
    func showOutcome(_ outcome: TakeOutcome) {
        clearOutcome()
        waiting = nil
        self.outcome = outcome
        setVisible(true)
        announceContent()
        let duration = outcomeDuration ?? outcome.duration
        outcomeHide = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            self.outcome = nil
            self.outcomeHide = nil
            self.lastAnnouncement = nil
            if self.isAtRest, self.notice == nil { self.setVisible(self.restsVisible) }
        }
    }

    private func clearOutcome() {
        outcomeHide?.cancel()
        outcomeHide = nil
        outcome = nil
    }

    private var isAtRest: Bool { state == .idle || state == .inserting }

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

    /// The take went hands-free, or stopped being so.
    func setHandsFree(finishKey: String?) {
        guard handsFreeFinishKey != finishKey else { return }
        handsFreeFinishKey = finishKey
        guard state == .listening, notice == nil, isVisible else { return }
        announceContent()
    }

    /// Show dictation status.
    func show(_ state: DictationState, elapsed: TimeInterval) {
        // Opening a closed microphone starts a take, even while the last
        // take's notice is still up and its hiding never ran: the new take
        // gets its tone, and the same notice ending it is news again.
        if state == .preparing || state == .listening, !isMicrophoneOpen {
            lastAnnouncement = nil
            hasCuedThisTake = false
            hasCuedHandsFree = false
        }
        cancelAutoHide()
        dismissAfterNotice = false
        // A take in progress is the news; how the last one ended is not.
        if state != .idle, state != .inserting { clearOutcome() }
        // A wait belongs to exactly one take. Leaving the flag set would let a
        // finished load narrate the next dictation.
        if state != .transcribing { isWaitingForEngine = false }
        if state != self.state { restartReveal(for: state) }
        self.state = state
        notice = nil
        // Once text is recognized, the destination application is the only
        // useful feedback surface. Do not cover it with a redundant insertion HUD.
        if state == .inserting {
            hide()
            return
        }
        // A new take starts flat. Transcribing keeps the last shape: the
        // waveform and the clock freeze at release, which is what says the
        // microphone has closed.
        if state == .preparing || state == .listening {
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
        // Words that did not land are not a four-second toast. The
        // application hands them to `setWaiting`, where they stay, in full,
        // with their action.
        if notice.recoverableText != nil, notice.wordsDidNotLand { return }
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
                self.setVisible(self.restsVisible)
                if self.restsVisible { self.announceContent() }
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
            // The take is over, and its microphone with it: a notice held
            // back while the microphone was open can be said now.
            announceContent()
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
        restartReveal(for: .idle)
        setVisible(restsVisible)
        // The next dictation must appear again, even if the state
        // matches the previous one.
        lastAnnouncement = nil
        hasCuedThisTake = false
        hasCuedHandsFree = false
        // Hands-free belongs to one take, like the model wait.
        handsFreeFinishKey = nil
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

    /// Titles and words wait out `titleDelay`: nine takes in ten are done by
    /// then, and those never show or say more than the take's shape.
    private func restartReveal(for state: DictationState) {
        reveal?.cancel()
        reveal = nil
        hasLingered = false
        guard state == .preparing || state == .transcribing else { return }
        let delay = titleDelay
        reveal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            // The same rule as the notice timer: a cancelled sleep returns at
            // once, and must not reveal the next state's title early.
            guard let self, !Task.isCancelled else { return }
            self.hasLingered = true
            guard self.notice == nil, self.isVisible else { return }
            self.announceContent()
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
        switch content.voice {
        case nil:
            return
        case .cue:
            if !hasCuedThisTake {
                hasCuedThisTake = true
                // Locked before the microphone opened: this tone is the
                // hands-free one as well.
                if content.mark == .handsFree { hasCuedHandsFree = true }
                announcer.playCue()
            } else if content.mark == .handsFree, !hasCuedHandsFree {
                hasCuedHandsFree = true
                announcer.playCue()
            }
        case let .speech(text, urgent):
            // Never into an open microphone, notices included: whatever
            // VoiceOver says now ends up in the transcript.
            guard !isMicrophoneOpen, text != lastAnnouncement else { return }
            lastAnnouncement = text
            announcer.announce(text, urgent: urgent)
        }
    }

    /// A dismissal waiting behind a notice means the take has ended, whatever
    /// state the panel last drew.
    private var isMicrophoneOpen: Bool {
        (state == .preparing || state == .listening) && !dismissAfterNotice
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    /// One unit tall: the slip plus the rim on both sides.
    private static let lineHeight = GlassTokens.Block.unit - 2 * GlassTokens.Block.rim

    var body: some View {
        if let content = model.visibleContent {
            block(content)
        } else {
            // Preserve the panel's initial preferred size for placement while
            // removing every animated and composited child from the retained
            // host view. In bottom placement, collapsing the height would put
            // the first expanded frame below the visible screen.
            Color.clear.frame(width: model.content.panelWidth, height: GlassTokens.Block.unit)
        }
    }

    private func block(_ content: OverlayContent) -> some View {
        Group {
            if let waiting = content.waiting {
                waitingWords(waiting)
            } else if content.tone != nil || content.outcome != nil {
                line(content)
            } else {
                take(content)
            }
        }
        .frame(width: content.panelWidth - 2 * GlassTokens.Block.rim, alignment: .leading)
        .wordSlip()
        .glassBlock(tint: content.rim)
        .accessibilityElement(children: content.waiting == nil ? .ignore : .contain)
        .accessibilityLabel(model.accessibilityLabel)
    }

    // MARK: A take

    /// Glyph, word, meter, clock: one shape from key-down to text.
    ///
    /// Static on purpose, in every state: this block is visible while the
    /// recognition result waits for the main actor, and an iterative effect
    /// drove a RenderBox/CA commit on every display refresh through the glass.
    private func take(_ content: OverlayContent) -> some View {
        HStack(spacing: 8) {
            if let glyph = content.glyph {
                StateGlyphView(glyph: glyph)
            }
            if let title = content.title {
                // Takes the place of the meter and the clock, so the block
                // keeps its size and nothing beside it moves.
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            } else {
                if let key = content.finishKey {
                    KeyCap(title: key)
                    Text(L10n.tr("ends"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                } else if let word = content.word {
                    Text(word)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                RecordingWaveform(
                    samples: model.waveformSamples,
                    color: content.mark?.colorRole?.color ?? .secondary,
                    height: 20
                )
                .frame(maxWidth: .infinity)
                .padding(.leading, 2)
                Text(elapsedText)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.lineHeight)
    }

    // MARK: A sentence

    /// A notice, or how a waiting take ended: one glyph and about eight words.
    private func line(_ content: OverlayContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let glyph = content.glyph {
                StateGlyphView(glyph: glyph)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            }
            Text(content.outcome?.message ?? content.title ?? "")
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: Self.lineHeight)
    }

    // MARK: Words that wait

    /// The words first: they are what the person is afraid of losing. Then
    /// why, then the one thing to do.
    private func waitingWords(_ waiting: WaitingWords) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(waiting.words)
                .font(.system(size: 17, weight: .semibold))
                .lineSpacing(1)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                // Read aloud only on request: the label names the state, and
                // the words belong to the person, not to the room.
                .accessibilityLabel(L10n.tr("Your words"))
                .accessibilityValue(waiting.words)

            if let note = waiting.note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if waiting.isCopied {
                // The words are on the clipboard: nothing is left to press
                // but the way out, so it shares the line.
                HStack(spacing: 8) {
                    reasonLine(waiting)
                    Spacer(minLength: 8)
                    laterButton
                }
            } else {
                reasonLine(waiting)
                HStack(spacing: 4) {
                    Button {
                        model.onWaitingAction?()
                    } label: {
                        HStack(spacing: 8) {
                            KeyCap(title: model.key.shortTitle, isPressed: model.isKeyDown, onInk: true)
                            Text(waiting.actionVerb)
                        }
                    }
                    .buttonStyle(InkButtonStyle())
                    .accessibilityLabel(
                        waiting.action == .copy ? L10n.tr("Copy") : L10n.tr("Paste")
                    )
                    Spacer(minLength: 0)
                    laterButton
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func reasonLine(_ waiting: WaitingWords) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StateGlyphView(glyph: waiting.glyph)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(waiting.reason(key: model.key.shortTitle))
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var laterButton: some View {
        Button(L10n.tr("Later")) { model.onWaitingLater?() }
            .buttonStyle(QuietButtonStyle())
            .accessibilityHint(L10n.tr("Keeps the words in History"))
    }

    private var elapsedText: String {
        let total = Int(max(0, model.elapsed).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}


extension DictationOverlay: RecordingFeedbackPresenting {
    func updateInputLevel(_ level: Float) {
        model.updateInputLevel(level)
    }
}
