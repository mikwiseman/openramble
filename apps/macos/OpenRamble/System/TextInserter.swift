import AppKit
import Carbon.HIToolbox
import DictationCore
import Foundation

// MARK: - Clipboard

/// Write the dictated text to the clipboard.
public protocol DictationPasteboard: Sendable {
    /// Keep valid previous contents in memory and put local text.
    func beginHostOnlyWrite(_ text: String) throws -> PasteboardTransaction
    /// Return the original content only if the post still belongs to us.
    func restore(_ transaction: PasteboardTransaction) throws
}

public struct PasteboardTransaction: Sendable, Equatable {
    fileprivate let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

private final class PasteboardTransactionStorage: @unchecked Sendable {
    struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let ownedChangeCount: Int
    }

    /// What is left of the transaction at the time of restore.
    enum Claim {
        /// Snapshot is still in memory - restoration is possible.
        case snapshot(Snapshot)
        /// Privacy budget has already erased the contents; All that remains is the ownership counter.
        /// According to it, restore distinguishes “a person has already copied his own” from “previous
        /// contents are lost forever."
        case expired(ownedChangeCount: Int)
        /// There was no transaction or it has already been restored.
        case missing
    }

    private let lock = NSLock()
    private var snapshots: [UUID: Snapshot] = [:]
    /// Tombstone expired snapshot. There is no content here - only Int,
    /// therefore the privacy budget is not violated.
    private var expiredOwnership: [UUID: Int] = [:]
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func insert(_ snapshot: Snapshot, for id: UUID) {
        lock.lock()
        // The old tombstone is no longer needed: a record that lands on our own dictation
        // takes it over through `inherit`, and everyone else lands on someone else's
        // contents, where the past ownership counter means nothing. The dictionary
        // does not grow indefinitely.
        expiredOwnership.removeAll()
        snapshots[id] = snapshot
        lock.unlock()

        // Even if the calling task died between write and restore,
        // sensitive snapshot does not survive the privacy budget. Three seconds:
        // seconds to consume ⌘V by a slow application (VoiceInk #722),
        // up to half a second to release modifiers and reserve for the scheduler.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + lifetime) { [weak self] in
            self?.expire(id)
        }
    }

    /// Remember only ownership: there is nothing to restore anymore.
    ///
    /// The fact itself cannot be lost. Losing it means that restore would consider
    /// the clipboard someone else's and would silently leave the dictation in it.
    func insertExpired(ownedChangeCount: Int, for id: UUID) {
        lock.lock()
        expiredOwnership.removeAll()
        expiredOwnership[id] = ownedChangeCount
        lock.unlock()
    }

    /// Give the pending contents of the person to the record that is about to replace
    /// our own dictation on the board.
    ///
    /// Two dictations within one restore window are commonplace: a short answer in the
    /// chat, and a second one a second later. For a record that lands on our own text,
    /// the person's clipboard is what the previous transaction holds - and only it. The
    /// transaction is taken away along with it: its own restore would be applied to a
    /// board that is no longer his.
    func inherit(ownedChangeCount: Int) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        if let id = snapshots.first(where: { $0.value.ownedChangeCount == ownedChangeCount })?.key,
           let snapshot = snapshots.removeValue(forKey: id) {
            return .snapshot(snapshot)
        }
        if let id = expiredOwnership.first(where: { $0.value == ownedChangeCount })?.key {
            expiredOwnership.removeValue(forKey: id)
            return .expired(ownedChangeCount: ownedChangeCount)
        }
        return .missing
    }

    func take(_ id: UUID) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        if let snapshot = snapshots.removeValue(forKey: id) {
            return .snapshot(snapshot)
        }
        if let owned = expiredOwnership.removeValue(forKey: id) {
            return .expired(ownedChangeCount: owned)
        }
        return .missing
    }

    private func expire(_ id: UUID) {
        lock.lock()
        if let snapshot = snapshots.removeValue(forKey: id) {
            expiredOwnership[id] = snapshot.ownedChangeCount
        }
        lock.unlock()
    }
}

/// A clipboard limited to this computer.
///
/// A regular recording sends the content to the Universal Clipboard, and the dictated
/// the text appears on all Apple ID devices via iCloud - directly contrary to
/// product promise. `prepareForNewContents(with: .currentHostOnly)` is
/// disables, and marks ask buffer managers not to save the entry to history.
///
/// Naked `clearContents()` is prohibited here, and this is checked separately -
/// `scripts/check-network-surface.sh`.
public struct HostOnlyPasteboard: DictationPasteboard {
    /// The convention of third-party clipboard managers is “do not save.”
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    /// Board name. In the appendix - general; in the test its own, so that the run does not overwrite
    /// what the person copied at that moment.
    private let name: String
    private let writeObjects: @Sendable (NSPasteboard, [NSPasteboardWriting]) -> Bool
    private let transactions: PasteboardTransactionStorage

    public init(name: String = NSPasteboard.Name.general.rawValue) {
        self.init(name: name, snapshotLifetime: 3) { pasteboard, objects in
            pasteboard.writeObjects(objects)
        }
    }

    init(
        name: String,
        snapshotLifetime: TimeInterval = 3,
        writeObjects: @escaping @Sendable (NSPasteboard, [NSPasteboardWriting]) -> Bool = {
            pasteboard, objects in
            pasteboard.writeObjects(objects)
        }
    ) {
        self.name = name
        self.writeObjects = writeObjects
        self.transactions = PasteboardTransactionStorage(lifetime: snapshotLifetime)
    }

    public func beginHostOnlyWrite(_ text: String) throws -> PasteboardTransaction {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        let observedChangeCount = pasteboard.changeCount
        // Restoration is deferred by a second after ⌘V, and the second dictation within
        // this second is normal life, not an edge case. If our own dictation is still on
        // the board, the person's contents are held by the previous transaction: a fresh
        // snapshot here would capture the dictated text instead of it - and the person's
        // clipboard would be lost forever, and the previous dictation would return to
        // the board instead.
        let inherited = transactions.inherit(ownedChangeCount: pasteboard.changeCount)
        let snapshot: [[NSPasteboard.PasteboardType: Data]]
        let inheritsLostContents: Bool
        switch inherited {
        case let .snapshot(previous):
            snapshot = previous.items
            inheritsLostContents = false
        case .expired:
            // The privacy budget has already erased the person's contents; only the fact
            // that the board is still ours has survived. This fact is passed on: restore
            // has to say it out loud, and not leave the dictation in the buffer silently.
            snapshot = []
            inheritsLostContents = true
        case .missing:
            snapshot = materializeSnapshot(from: pasteboard)
            inheritsLostContents = false
            // Materializing a lazy clipboard promise can block in another
            // process. If the user copied something while that read was
            // suspended, do not overwrite the newer clipboard when it
            // eventually returns.
            guard pasteboard.changeCount == observedChangeCount else {
                throw TextInsertionError.clipboardWriteFailed
            }
        }

        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let ownedChangeCount = pasteboard.changeCount
        guard writeObjects(pasteboard, [dictatedItem(text)]) else {
            do {
                try restoreSnapshot(snapshot, to: pasteboard, ownedChangeCount: ownedChangeCount)
            } catch {
                throw TextInsertionError.clipboardRestoreFailed
            }
            throw TextInsertionError.clipboardWriteFailed
        }

        let transaction = PasteboardTransaction()
        if inheritsLostContents {
            transactions.insertExpired(
                ownedChangeCount: pasteboard.changeCount,
                for: transaction.id
            )
        } else {
            transactions.insert(
                .init(items: snapshot, ownedChangeCount: pasteboard.changeCount),
                for: transaction.id
            )
        }
        return transaction
    }

    /// Explicit Copy command: the user himself allowed to replace the clipboard, but
    /// The dictation should still not go to Universal Clipboard or history.
    public func copyHostOnly(_ text: String) throws {
        try write(text, to: NSPasteboard(name: NSPasteboard.Name(name)))
    }

    public func restore(_ transaction: PasteboardTransaction) throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        // `take` simultaneously clears the sensitive snapshot from memory - even
        // when ownership is already lost and nothing can be restored.
        switch transactions.take(transaction.id) {
        case let .snapshot(snapshot):
            try restoreSnapshot(
                snapshot.items,
                to: pasteboard,
                ownedChangeCount: snapshot.ownedChangeCount
            )
        case let .expired(ownedChangeCount):
            // Privacy budget has already erased the person's previous content. If a person
            // I have since copied mine - there is nothing to restore and this is not an error.
            guard pasteboard.changeCount == ownedChangeCount else { return }
            // Clipboard is still ours: it contains dictation. You can't leave her
            // and “success” here would be a silent loss of the person’s contents.
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            throw TextInsertionError.clipboardRestoreFailed
        case .missing:
            return
        }
    }

    private func materializeSnapshot(
        from pasteboard: NSPasteboard
    ) -> [[NSPasteboard.PasteboardType: Data]] {
        var result: [[NSPasteboard.PasteboardType: Data]] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // Clipboard metadata such as ConcealedType is data like any other type.
                // It must never block dictation. Lazy file promises may not materialize
                // outside a drag session; preserve every representation that is available.
                if let data = item.data(forType: type) { values[type] = data }
            }
            if !values.isEmpty { result.append(values) }
        }
        return result
    }

    private func write(_ text: String, to pasteboard: NSPasteboard) throws {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard writeObjects(pasteboard, [dictatedItem(text)]) else {
            throw TextInsertionError.clipboardWriteFailed
        }
    }

    private func dictatedItem(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: Self.transientType)
        item.setString("", forType: Self.concealedType)
        item.setString("", forType: Self.autoGeneratedType)
        return item
    }

    private func restoreSnapshot(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard,
        ownedChangeCount: Int
    ) throws {
        guard pasteboard.changeCount == ownedChangeCount else { return }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard !snapshot.isEmpty else { return }
        let restored = snapshot.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        guard writeObjects(pasteboard, restored) else {
            throw TextInsertionError.clipboardWriteFailed
        }
    }
}

// MARK: - System edges

/// Everything that the insert asks the system and does with it.
///
/// Behind the protocol - because the real answers depend on what the person
/// doing at the computer right now: is the password field open, what keys
/// clamped, whether the application is alive, where we are aiming.
public protocol InputSystem: Sendable {
    /// Secure input: password field, terminal with keyboard protection, manager
    /// passwords. The system prohibits both sending events and reading the keyboard there.
    var isSecureInputEnabled: Bool { get }
    var isAccessibilityTrusted: Bool { get }
    func frontmostApplication() -> TargetApplication?
    /// Which modifiers are clamped right now.
    func heldModifiers() -> CGEventFlags
    /// Return focus to the application. `false` - the application no longer exists.
    func activate(_ target: TargetApplication) async -> Bool
    /// Post to the captured process when one is known. A delayed WindowServer
    /// return must never redirect an old dictation into whichever app happens
    /// to be frontmost later.
    func post(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        targetProcessIdentifier: Int32?
    ) throws
}

public struct SystemInput: InputSystem {
    public init() {}

    public var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }
    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    public func frontmostApplication() -> TargetApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return TargetApplication(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            localizedName: app.localizedName
        )
    }

    public func heldModifiers() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
    }

    public func activate(_ target: TargetApplication) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return false
        }
        guard !app.isActive else { return true }

        app.activate()
        // A short pause: switching focus is not instantaneous, but pressing,
        // sent ahead of time will go to the wrong place.
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return false
        }
        return true
    }

    public func post(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        targetProcessIdentifier: Int32?
    ) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw TextInsertionError.targetUnavailable
        }

        keyDown.flags = flags
        keyUp.flags = flags
        if let targetProcessIdentifier {
            keyDown.postToPid(pid_t(targetProcessIdentifier))
            keyUp.postToPid(pid_t(targetProcessIdentifier))
        } else {
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
    }
}

// MARK: - Insert

/// Insert recognized text into the active application.
///
/// Works via the clipboard and synthetic pressing ⌘V: this is the only one
/// a way to insert text into an arbitrary application without knowing its device.
/// Carries a failed deferred restore to whoever can show it.
///
/// `TextInserter` is a value type built before `AppState` exists, so a callback
/// assigned afterwards would land on a copy and never fire. A reference handed
/// in at construction closes that gap honestly.
public final class ClipboardRestoreReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (TextInsertionError) -> Void)?

    public init() {}

    public func onFailure(_ handler: @escaping @Sendable (TextInsertionError) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    func report(_ error: TextInsertionError) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(error)
    }
}

/// Process-wide ownership of the clipboard + synthetic-event transaction.
///
/// Controller deadlines may abandon a synchronous WindowServer call, but the
/// call itself can still return later. Until it does, changing the clipboard
/// for another dictation would let the old Cmd+V consume the new text (or the
/// user's restored clipboard). The lane therefore remains owned by the real
/// operation, not by the controller's bounded waiter. Later insertions fail
/// fast and keep their recognized text in recovery instead of corrupting two
/// applications at once.
final class TextInsertionLane: @unchecked Sendable {
    static let shared = TextInsertionLane()

    private enum Owner {
        case idle
        case insertion
        case restoration
    }

    private struct ScheduledRestore {
        let generation: UInt64
        let operation: @Sendable () -> Void
        var isDue = false
        var timer: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var owner = Owner.idle
    private var restoreGeneration: UInt64 = 0
    /// At most one restore is pending. A successful N+1 write inherits N's
    /// snapshot, so only the newest transaction can still put the person's
    /// clipboard back. Replacing its timer keeps a burst of short dictations
    /// from accumulating detached restore tasks.
    private var scheduledRestore: ScheduledRestore?

    func tryAcquire() -> Bool {
        lock.withLock {
            guard owner == .idle else { return false }
            owner = .insertion
            return true
        }
    }

    func release() {
        let dueRestore: (@Sendable () -> Void)? = lock.withLock {
            guard owner == .insertion else {
                assertionFailure("only an insertion owner can release this lane")
                return nil
            }

            guard let restore = scheduledRestore, restore.isDue else {
                owner = .idle
                return nil
            }

            scheduledRestore = nil
            owner = .restoration
            return restore.operation
        }

        if let dueRestore {
            performRestore(dueRestore)
        }
    }

    /// Schedule the production restore before releasing insertion ownership.
    ///
    /// During the delay another insertion may safely inherit the snapshot and
    /// replace this single ticket. Once the ticket becomes due, either restore
    /// takes the lane first or an insertion does. In the latter case release
    /// hands the lane directly to restore, leaving no clear/write race window.
    func scheduleRestore(
        after delay: Duration,
        operation: @escaping @Sendable () -> Void
    ) {
        let generation: UInt64
        let previousTimer: Task<Void, Never>?
        (generation, previousTimer) = lock.withLock {
            assert(owner == .insertion, "restore must be scheduled by the insertion owner")
            restoreGeneration &+= 1
            let generation = restoreGeneration
            let previousTimer = scheduledRestore?.timer
            scheduledRestore = ScheduledRestore(
                generation: generation,
                operation: operation
            )
            return (generation, previousTimer)
        }
        previousTimer?.cancel()

        // The lane stores only the newest timer. Superseded sleeps are
        // cancelled, so a burst cannot leave an unbounded restore queue.
        let timer = Task.detached(priority: .utility) { [self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            restoreBecameDue(generation: generation)
        }

        let wasSuperseded = lock.withLock {
            guard scheduledRestore?.generation == generation else { return true }
            scheduledRestore?.timer = timer
            return false
        }
        if wasSuperseded {
            timer.cancel()
        }
    }

    private func restoreBecameDue(generation: UInt64) {
        let restore: (@Sendable () -> Void)? = lock.withLock {
            guard var scheduled = scheduledRestore,
                  scheduled.generation == generation
            else { return nil }

            scheduled.timer = nil
            guard owner == .idle else {
                // The current insertion either replaces this ticket after it
                // inherits the snapshot, or hands the lane to it on release.
                scheduled.isDue = true
                scheduledRestore = scheduled
                return nil
            }

            scheduledRestore = nil
            owner = .restoration
            return scheduled.operation
        }

        if let restore {
            performRestore(restore)
        }
    }

    private func performRestore(_ operation: @Sendable () -> Void) {
        defer {
            lock.withLock {
                assert(owner == .restoration, "restore lost ownership of the insertion lane")
                owner = .idle
            }
        }
        operation()
    }
}

public struct TextInserter: TextInserting {
    /// Modifiers, the release of which we wait for before ⌘V.
    ///
    /// Otherwise, ⌘V will mix with the held modifier and turn into someone else's
    /// combination - for example, in Fn+⌘V, which the application will understand completely differently.
    ///
    /// Fn is required in the list: it is a hotkey available in the settings, and
    /// without it, the wait would end while the key is still held.
    public static let watchedModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
    ]

    /// How long to wait for release and in what steps.
    static let releasePollLimit = 50
    static let releasePollInterval = Duration.milliseconds(10)
    private let system: any InputSystem
    private let pasteboard: any DictationPasteboard
    private let restoreDelay: Duration
    /// Where a failed deferred restore is reported.
    ///
    /// The restore is fire-and-forget a second after the paste, so there is
    /// nobody left to throw to. Without this the person silently loses whatever
    /// they had copied, and the dictated text stays on the board in its place.
    private let restoreReporter: ClipboardRestoreReporter?
    private let operationLane: TextInsertionLane

    public init(
        system: any InputSystem = SystemInput(),
        pasteboard: any DictationPasteboard = HostOnlyPasteboard(),
        restoreDelay: Duration = .milliseconds(1000),
        restoreReporter: ClipboardRestoreReporter? = nil
    ) {
        self.init(
            system: system,
            pasteboard: pasteboard,
            restoreDelay: restoreDelay,
            restoreReporter: restoreReporter,
            operationLane: .shared
        )
    }

    init(
        system: any InputSystem,
        pasteboard: any DictationPasteboard,
        restoreDelay: Duration,
        restoreReporter: ClipboardRestoreReporter? = nil,
        operationLane: TextInsertionLane
    ) {
        self.system = system
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.restoreReporter = restoreReporter
        self.operationLane = operationLane
    }

    public func frontmostApplication() -> TargetApplication? {
        system.frontmostApplication()
    }

    /// A wrapper over a single implementation.
    ///
    /// There is exactly one body. The two bodies would separate, and the speed display would show
    /// the path that the product does not take.
    public func insert(_ text: String, into target: TargetApplication?) async throws {
        _ = try await insertReportingMarks(text, into: target)
    }

    public func insertReportingMarks(
        _ text: String,
        into target: TargetApplication?
    ) async throws -> InsertionMarks {
        try Task.checkCancellation()
        guard !text.isEmpty else { return InsertionMarks() }
        guard let target else { throw TextInsertionError.targetUnavailable }
        guard operationLane.tryAcquire() else {
            throw TextInsertionError.insertionInProgress
        }
        defer { operationLane.release() }

        // Protected input is not a failure, but a normal situation.
        guard !system.isSecureInputEnabled else {
            throw TextInsertionError.secureInputActive
        }
        guard system.isAccessibilityTrusted else {
            throw TextInsertionError.accessibilityPermissionDenied
        }

        // Return focus BEFORE writing to the buffer. If the application is no longer available, continue
        // you can’t go, and the buffer has not yet been touched at this moment: otherwise the person
        // would lose what was copied where the pasting did not take place anyway.
        try await activate(target)
        try Task.checkCancellation()
        try validateTarget(target)
        try validateProtectedState()

        let transaction = try pasteboard.beginHostOnlyWrite(text)
        let pasteDispatchedAt: ContinuousClock.Instant
        do {
            // If a bounded controller wait expired while a synchronous
            // pasteboard call was blocked, restore rather than dispatching a
            // late paste into a session that has already returned to idle.
            try Task.checkCancellation()
            try await waitForModifiersRelease()
            try Task.checkCancellation()
            // The last check is performed after changing the clipboard and directly
            // before an irreversible event Cmd+V.
            try validateTarget(target)
            try validateProtectedState()
            try Task.checkCancellation()
            try system.post(
                keyCode: CGKeyCode(kVK_ANSI_V),
                flags: .maskCommand,
                targetProcessIdentifier: target.processIdentifier
            )
            // Header: from now on, the text is in someone else's window.
            // Everything further is buffer protection, and it is not speed.
            pasteDispatchedAt = .now
        } catch {
            do {
                try pasteboard.restore(transaction)
            } catch {
                throw TextInsertionError.clipboardRestoreFailed
            }
            throw error
        }

        // Slow apps may consume the pasteboard from a later event-loop turn. Keep the
        // dictated text available for one second, but do not keep the UI in an
        // “Inserting” state after Cmd+V has already been dispatched.
        if restoreDelay == .zero {
            do {
                try pasteboard.restore(transaction)
            } catch {
                throw TextInsertionError.insertedButClipboardRestoreFailed
            }
            return InsertionMarks(
                pasteDispatchedAt: pasteDispatchedAt,
                clipboardRestoredAt: .now
            )
        }

        let pasteboard = self.pasteboard
        let reporter = self.restoreReporter
        operationLane.scheduleRestore(after: restoreDelay) {
            do {
                try pasteboard.restore(transaction)
            } catch {
                // The insertion itself succeeded, so this cannot be thrown — the
                // caller is long gone. Reporting it is the only honest option:
                // what failed here is putting the person's own clipboard back,
                // and on the shipping path (a one second delay) this branch is
                // the ONLY one that can say so. The zero-delay branch above
                // throws, but production never uses it, so before this callback
                // existed the loss was completely silent.
                reporter?.report(.insertedButClipboardRestoreFailed)
            }
        }
        return InsertionMarks(pasteDispatchedAt: pasteDispatchedAt)
    }

    public func pressReturn() async throws {
        try await pressReturn(into: nil)
    }

    public func pressReturn(into target: TargetApplication?) async throws {
        try Task.checkCancellation()
        guard operationLane.tryAcquire() else {
            throw TextInsertionError.insertionInProgress
        }
        defer { operationLane.release() }
        guard !system.isSecureInputEnabled else {
            throw TextInsertionError.secureInputActive
        }
        guard system.isAccessibilityTrusted else {
            throw TextInsertionError.accessibilityPermissionDenied
        }
        try Task.checkCancellation()
        try system.post(
            keyCode: CGKeyCode(kVK_Return),
            flags: [],
            targetProcessIdentifier: target?.processIdentifier
        )
    }

    /// Return focus to the application where the dictation began.
    ///
    /// The application could be closed while recognition was in progress. Insert "somewhere"
    /// in this case it is impossible: there is now an arbitrary window ahead - up to someone else's
    /// password fields, and what was dictated would go there.
    private func activate(_ target: TargetApplication) async throws {
        guard await system.activate(target) else {
            throw TextInsertionError.targetUnavailable
        }
    }

    private func validateTarget(_ target: TargetApplication) throws {
        guard system.frontmostApplication()?.processIdentifier == target.processIdentifier else {
            throw TextInsertionError.targetChanged
        }
    }

    private func validateProtectedState() throws {
        guard !system.isSecureInputEnabled else {
            throw TextInsertionError.secureInputActive
        }
        guard system.isAccessibilityTrusted else {
            throw TextInsertionError.accessibilityPermissionDenied
        }
    }

    private func waitForModifiersRelease() async throws {
        for _ in 0..<Self.releasePollLimit {
            if system.heldModifiers().intersection(Self.watchedModifiers).isEmpty { return }
            try await Task.sleep(for: Self.releasePollInterval)
        }
        throw TextInsertionError.modifiersStillHeld
    }
}
