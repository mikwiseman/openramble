import ApplicationServices
import DictationCore
import Foundation

/// Reading the field into which the dictation was just inserted.
///
/// This is the only thing that the application reads from other people's windows: the value is exactly that
/// fields where it inserted the text itself, and exactly in the learning window - to learn
/// human edits. Nothing else is ever readable on the screen.
///
/// The edge of the system, not the detail: substituted through `AppEnvironment`, like a microphone
/// and insert. The promise “disabled means the field is not read” is otherwise unverifiable,
/// namely, unverifiability is what allowed him to be untrue for six months: tumbler
/// existed only in this comment, and it was not in the settings.
@MainActor
public protocol FocusedFieldReading {
    /// A snapshot of the focused field. `nil` - there is no field or it is not readable.
    func captureFocusedField() -> FocusedFieldHandle?
}

/// Field Handle: Rereads the value while the field is alive.
@MainActor
public final class FocusedFieldHandle {
    private let read: () -> String?

    public init(read: @escaping () -> String?) {
        self.read = read
    }

    public func value() -> String? { read() }
}

@MainActor
public struct SystemFocusedFieldReader: FocusedFieldReading {
    public init() {}

    public func captureFocusedField() -> FocusedFieldHandle? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let element = Self.element(from: focused) else { return nil }
        return FocusedFieldHandle {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                element,
                kAXValueAttribute as CFString,
                &value
            )
            guard status == .success else { return nil }
            return value as? String
        }
    }

    /// The focused element, if this is really an element.
    ///
    /// The value is given away by the accessibility server of ANOTHER application, and its
    /// type is that application's word, not our guarantee. Swift does not check a cast to
    /// a CoreFoundation type at all - neither `as!` nor `as?` - so an unchecked cast stops
    /// nothing: someone else's object goes on into `AXUIElementCopyAttributeValue`, and
    /// what happens there depends on the framework, not on us. Comparing type identifiers
    /// is the only real check, and the rest of this file is defensive for the same reason:
    /// the price of an unread field is one unlearned word, and the price of a foreign
    /// object passed on during a dictation is unknown.
    static func element(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

/// When the observer rereads the field into which it was inserted.
///
/// The numbers are not an implementation detail: the settings say “twice — at 8 and 25
/// seconds”, and `learnFromEdits` says “only in the first half a minute”. This is the one
/// place where the application reads inside someone else's window, so the word about WHEN
/// must be exactly true. Spent as a chain of pauses, these same two numbers would take the
/// second reading to the 33rd second - beyond the promised half a minute, and beyond what a
/// person agreed to when he turned on the switch. Hence the offsets from the insertion,
/// hence a separate type: a place where the promise and the code are one line apart.
enum EditLearningSchedule {
    /// Offsets from the moment of insertion, in order.
    static let checkOffsets: [Duration] = [.seconds(8), .seconds(25)]

    /// The boundary promised in the settings: nothing is read later.
    static let limit: Duration = .seconds(30)

    /// Turn the offsets from the insertion into pauses that a sequential loop sleeps.
    static func waits(between offsets: [Duration]) -> [Duration] {
        var waits: [Duration] = []
        var elapsed = Duration.zero
        for offset in offsets {
            waits.append(max(.zero, offset - elapsed))
            elapsed = max(elapsed, offset)
        }
        return waits
    }
}

/// Edit observer: rereads the field twice after insertion and turns
/// editing the inserted fragment into the training signal.
///
/// This is a decoration on top of the dictation: any failure - the field disappears, the value is not
/// is read, the entire fragment is rewritten - it simply completes the observation.
/// Lack of training is evident in the dictionary; You can’t break the dictation because of him.
@MainActor
final class EditLearningWatcher {
    private let reader: any FocusedFieldReading
    private let checkOffsets: [Duration]
    private var watch: Task<Void, Never>?

    init(
        reader: any FocusedFieldReading = SystemFocusedFieldReader(),
        checkOffsets: [Duration] = EditLearningSchedule.checkOffsets
    ) {
        self.reader = reader
        self.checkOffsets = checkOffsets
    }

    /// Start observing the text you just inserted.
    ///
    /// The new insert cancels the previous observation: you can only learn what
    /// man rules right now.
    func beginWatching(
        inserted: String,
        onEdit: @escaping @MainActor (_ original: String, _ edited: String) -> Void
    ) {
        cancel()
        guard let field = reader.captureFocusedField() else { return }
        guard let baseline = field.value(), baseline.contains(inserted) else { return }

        let waits = EditLearningSchedule.waits(between: checkOffsets)
        watch = Task { @MainActor in
            for wait in waits {
                if wait > .zero { try? await Task.sleep(for: wait) }
                guard !Task.isCancelled else { return }
                guard let current = field.value() else { return }
                if let edit = InsertedEditExtractor.extract(
                    baseline: baseline,
                    current: current,
                    inserted: inserted
                ) {
                    onEdit(edit.original, edit.edited)
                    return
                }
            }
        }
    }

    func cancel() {
        watch?.cancel()
        watch = nil
    }
}
