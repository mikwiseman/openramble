import AppKit
import Carbon.HIToolbox
import DictationCore
import Foundation

// MARK: - Clipboard

/// Write the dictated text to the clipboard.
public protocol DictationPasteboard: Sendable {
    /// Keep valid previous contents in memory and put local text.
    func beginHostOnlyWrite(_ text: String) throws -> PasteboardTransaction
    /// When an application first read the dictated text; `nil` while nobody has.
    ///
    /// The receipt that a paste landed. Once the transaction is restored no read
    /// can be added, so asking after `restore` gives the final answer.
    func firstRead(of transaction: PasteboardTransaction) -> ContinuousClock.Instant?
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
    /// When the dictation was first handed to a reader. Instants only.
    private var firstReads: [UUID: ContinuousClock.Instant] = [:]
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func insert(_ snapshot: Snapshot, for id: UUID) {
        lock.lock()
        // The insertion lane admits one transaction at a time, so every earlier
        // one is finished: its tombstone and receipt mean nothing any more, and
        // the dictionaries do not grow indefinitely.
        expiredOwnership.removeAll()
        firstReads.removeAll()
        snapshots[id] = snapshot
        lock.unlock()

        // Even if the calling task died between write and restore, the
        // sensitive snapshot does not survive the privacy budget. Five seconds:
        // the three-second wait for the target to read ⌘V, up to half a second
        // to release modifiers, and a reserve for the scheduler.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + lifetime) { [weak self] in
            self?.expire(id)
        }
    }

    /// Hand the dictation over, but only while the transaction is open, and
    /// note the moment.
    ///
    /// Under the lock, so it never interleaves with `take`: a read that wins is
    /// on record before the restore decides anything, and one that loses gets
    /// nothing at all - never the dictation after the person's clipboard is back.
    func provide(for id: UUID, _ handOver: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard snapshots[id] != nil || expiredOwnership[id] != nil else { return }
        handOver()
        if firstReads[id] == nil { firstReads[id] = .now }
    }

    func firstRead(_ id: UUID) -> ContinuousClock.Instant? {
        lock.withLock { firstReads[id] }
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

/// Serves the dictated text to whichever application reads it first.
///
/// AppKit asks for the data at most once per write and caches the answer, and
/// it asks on the main thread. That single call is the read receipt.
private final class DictationDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let id: UUID
    private let transactions: PasteboardTransactionStorage

    init(text: String, id: UUID, transactions: PasteboardTransactionStorage) {
        self.text = text
        self.id = id
        self.transactions = transactions
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        transactions.provide(for: id) {
            item.setString(text, forType: type)
        }
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
        self.init(name: name, snapshotLifetime: 5) { pasteboard, objects in
            pasteboard.writeObjects(objects)
        }
    }

    init(
        name: String,
        snapshotLifetime: TimeInterval = 5,
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
        let snapshot = materializeSnapshot(from: pasteboard)
        // Materializing a lazy clipboard promise can block in another
        // process. If the user copied something while that read was
        // suspended, do not overwrite the newer clipboard when it
        // eventually returns.
        guard pasteboard.changeCount == observedChangeCount else {
            throw TextInsertionError.clipboardWriteFailed
        }

        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let ownedChangeCount = pasteboard.changeCount
        let transaction = PasteboardTransaction()
        // On record before the item is visible, so a reader that comes at once
        // is served rather than refused.
        transactions.insert(
            .init(items: snapshot, ownedChangeCount: ownedChangeCount),
            for: transaction.id
        )
        guard writeObjects(pasteboard, [lazyDictatedItem(text, for: transaction)]) else {
            _ = transactions.take(transaction.id)
            do {
                try restoreSnapshot(snapshot, to: pasteboard, ownedChangeCount: ownedChangeCount)
            } catch {
                throw TextInsertionError.clipboardRestoreFailed
            }
            throw TextInsertionError.clipboardWriteFailed
        }
        return transaction
    }

    public func firstRead(of transaction: PasteboardTransaction) -> ContinuousClock.Instant? {
        transactions.firstRead(transaction.id)
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
        markDoNotKeep(item)
        return item
    }

    /// The paste's item: the text is handed out on demand, so the first read is
    /// a receipt. The markers stay eager - a clipboard manager decides from
    /// them without asking for the text.
    private func lazyDictatedItem(
        _ text: String,
        for transaction: PasteboardTransaction
    ) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let provider = DictationDataProvider(text: text, id: transaction.id, transactions: transactions)
        item.setDataProvider(provider, forTypes: [.string])
        markDoNotKeep(item)
        return item
    }

    private func markDoNotKeep(_ item: NSPasteboardItem) {
        item.setString("", forType: Self.transientType)
        item.setString("", forType: Self.concealedType)
        item.setString("", forType: Self.autoGeneratedType)
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
    /// The key that types "v" with ⌘ held in the layout in use right now.
    func pasteKeyCode() async -> CGKeyCode
    /// Press a key the way a keyboard does: the system delivers it to the key
    /// window, panels included (Spotlight, Raycast), which a post to a process
    /// would miss. ⌘V and Return take this one route, so a dictation never
    /// splits between two windows; the caller checks the target is still in
    /// front right before each press.
    func post(keyCode: CGKeyCode, flags: CGEventFlags) throws
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

    public func pasteKeyCode() async -> CGKeyCode {
        // Text Input Sources are main-thread API on older systems.
        await MainActor.run { PasteKey.current() }
    }

    public func post(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw TextInsertionError.targetUnavailable
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

/// Which key pastes.
///
/// ⌘V is a character shortcut, not a key position. The ANSI V key types ⌘K on
/// Dvorak and ⌘C - copy instead of paste - on Turkish F. So the paste uses the
/// key that types "v" with ⌘ held in the current layout, and the ANSI V key
/// when no key does.
enum PasteKey {
    static func keyCode(translating characterFor: (CGKeyCode) -> String?) -> CGKeyCode {
        let ansiV = CGKeyCode(kVK_ANSI_V)
        if characterFor(ansiV) == "v" { return ansiV }
        return (0..<128).map { CGKeyCode($0) }.first { characterFor($0) == "v" } ?? ansiV
    }

    /// What each key types with ⌘ held, from a layout's `uchr` data.
    static func characters(in layoutData: CFData) -> (CGKeyCode) -> String? {
        { keyCode in
            guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                UInt32((cmdKey >> 8) & 0xFF),
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    @MainActor
    static func current() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return CGKeyCode(kVK_ANSI_V) }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        return keyCode(translating: characters(in: layoutData))
    }
}

// MARK: - Insert

/// Carries a restore that failed after the paste landed to whoever can show it.
///
/// The words are in the target, so the insertion succeeded and must be reported
/// as one: the controller then keeps it as the last dictation, learns from it,
/// and presses Return for "Send it.". What failed is putting the person's own
/// clipboard back, and that is said on the side, never swallowed.
///
/// `TextInserter` is a value type built before `AppState` exists, so a callback
/// assigned afterwards would land on a copy and never fire. A reference handed
/// in at construction closes that gap honestly.
public final class ClipboardRestoreReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    public init() {}

    public func onFailure(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    func report() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }
}

/// Process-wide ownership of the clipboard + synthetic-event transaction:
/// write, ⌘V, the wait for the target to read, and the restore.
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

    private let lock = NSLock()
    private var isOwned = false

    func tryAcquire() -> Bool {
        lock.withLock {
            guard !isOwned else { return false }
            isOwned = true
            return true
        }
    }

    func release() {
        lock.withLock {
            assert(isOwned, "only the owner can release this lane")
            isOwned = false
        }
    }
}

/// Insert recognized text into the active application.
///
/// Works via the clipboard and synthetic pressing ⌘V: this is the only one
/// a way to insert text into an arbitrary application without knowing its device.
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

    /// The person's clipboard comes back this long after the target's read.
    /// The target's follow-up reads (Chromium's source types) end within 9 ms.
    static let readQuiet = Duration.milliseconds(50)
    /// ...and never sooner than this after ⌘V: twice the slowest first read on
    /// real takes (122 ms). A read cannot say which application made it, so a
    /// clipboard watcher that reads first must not take the text away from a
    /// target that is about to.
    static let readFloor = Duration.milliseconds(250)
    /// No read by then means nothing was pasted.
    static let readLimit = Duration.seconds(3)
    static let readPollInterval = Duration.milliseconds(5)
    /// How long a caller may wait for an insertion: the read limit, plus room
    /// to activate the target and release the modifiers before ⌘V.
    public static let insertionDeadline = readLimit + .seconds(2)

    private let system: any InputSystem
    private let pasteboard: any DictationPasteboard
    private let readQuiet: Duration
    private let readFloor: Duration
    private let readLimit: Duration
    private let restoreReporter: ClipboardRestoreReporter?
    private let operationLane: TextInsertionLane

    public init(
        system: any InputSystem = SystemInput(),
        pasteboard: any DictationPasteboard = HostOnlyPasteboard(),
        restoreReporter: ClipboardRestoreReporter? = nil
    ) {
        self.init(
            system: system,
            pasteboard: pasteboard,
            restoreReporter: restoreReporter,
            operationLane: .shared
        )
    }

    init(
        system: any InputSystem,
        pasteboard: any DictationPasteboard,
        readQuiet: Duration = Self.readQuiet,
        readFloor: Duration = Self.readFloor,
        readLimit: Duration = Self.readLimit,
        restoreReporter: ClipboardRestoreReporter? = nil,
        operationLane: TextInsertionLane
    ) {
        self.system = system
        self.pasteboard = pasteboard
        self.readQuiet = readQuiet
        self.readFloor = readFloor
        self.readLimit = readLimit
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
        // Read once the target is in front: the layout follows the document.
        let pasteKey = await system.pasteKeyCode()

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
            try system.post(keyCode: pasteKey, flags: .maskCommand)
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

        // The dictation stays on the board until the target has read it; then
        // the person's clipboard comes back. Both happen before returning: the
        // target's read is served from our main thread, so nothing the caller
        // does on the main actor next may run before it.
        let wasCancelled = await waitForTheRead(of: transaction, pastedAt: pasteDispatchedAt)
        var restoredAt: ContinuousClock.Instant?
        do {
            try pasteboard.restore(transaction)
            restoredAt = .now
        } catch {
            restoredAt = nil
        }
        // Asked after the restore, which closes the receipt: a read that slipped
        // in just before it still counts, and none can come later.
        guard let firstReadAt = pasteboard.firstRead(of: transaction) else {
            if restoredAt == nil { throw TextInsertionError.clipboardRestoreFailed }
            if wasCancelled { throw CancellationError() }
            throw TextInsertionError.pasteNotRead
        }
        if restoredAt == nil {
            restoreReporter?.report()
        }
        return InsertionMarks(
            pasteDispatchedAt: pasteDispatchedAt,
            clipboardRestoredAt: restoredAt,
            firstReadAt: firstReadAt
        )
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
        try validateProtectedState()
        // Return goes where the paste went, and only while the dictation's
        // application is still in front: it is irreversible.
        if let target { try validateTarget(target) }
        try Task.checkCancellation()
        try system.post(keyCode: CGKeyCode(kVK_Return), flags: [])
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

    /// Wait until the target has read the paste, or until the limit says
    /// nobody will. Returns whether cancellation cut the wait short.
    ///
    /// One rule for every read: a quiet moment after it, and never before the
    /// floor. A read before ⌘V, or one by a clipboard watcher just after it,
    /// then costs at most the floor - never a false alarm, and never the text
    /// taken away from a target that reads a moment later.
    private func waitForTheRead(
        of transaction: PasteboardTransaction,
        pastedAt: ContinuousClock.Instant
    ) async -> Bool {
        while true {
            let now = ContinuousClock.now
            if let read = pasteboard.firstRead(of: transaction) {
                if now >= max(read + readQuiet, pastedAt + readFloor) { return false }
            } else if now >= pastedAt + readLimit {
                return false
            }
            do {
                try await Task.sleep(for: Self.readPollInterval)
            } catch {
                return true
            }
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
