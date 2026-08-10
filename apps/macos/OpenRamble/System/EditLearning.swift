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
        guard result == .success, let focused else { return nil }
        let element = focused as! AXUIElement
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
    private let checkDelays: [Duration]
    private var watch: Task<Void, Never>?

    init(
        reader: any FocusedFieldReading = SystemFocusedFieldReader(),
        checkDelays: [Duration] = [.seconds(8), .seconds(25)]
    ) {
        self.reader = reader
        self.checkDelays = checkDelays
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

        watch = Task { @MainActor [checkDelays] in
            for delay in checkDelays {
                try? await Task.sleep(for: delay)
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
