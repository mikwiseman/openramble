import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What a recorder does with a key press. Pure, so the rules are testable
/// without a keyboard.
enum ShortcutRecording {
    enum Outcome: Equatable {
        /// Recorded; stop listening.
        case commit(KeyCombination)
        /// Binding removed; stop listening.
        case clear
        /// Stop listening, change nothing.
        case cancel
        /// Not a shortcut anyone can use — keep listening and say why.
        case reject(String)
    }

    /// Escape leaves the field alone; Delete empties it. Both are what a
    /// person expects from every other recorder on the machine, and neither
    /// can be recorded as a shortcut because of it.
    static func outcome(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Outcome {
        let combination = KeyCombination(keyCode: keyCode, modifiers: modifiers)
        if keyCode == UInt16(kVK_Escape), combination.modifierFlags.isEmpty {
            return .cancel
        }
        if keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete),
           combination.modifierFlags.isEmpty {
            return .clear
        }
        guard combination.isValid else {
            return .reject("Add ⌘, ⌃ or ⌥ — a plain key would fire while you type.")
        }
        return .commit(combination)
    }
}

/// Click it, press the keys you want.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyCombination?
    /// Shortcuts already spoken for elsewhere, with the name to blame.
    var reserved: [KeyCombination: String] = [:]

    @State private var isRecording = false
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                isRecording.toggle()
                problem = nil
            } label: {
                Text(label)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(labelColor)
                    .frame(minWidth: 86)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .focused($isFocused)
            .accessibilityLabel("Shortcut")
            .accessibilityValue(shortcut?.displayString ?? "None")
            .accessibilityHint(
                isRecording
                    ? "Press the keys you want. Escape cancels, Delete removes it."
                    : "Activate, then press the keys you want"
            )

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(StatusColorRole.attention.color)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: isRecording) { _, recording in
            // The catcher lives exactly as long as the recording does. A key
            // catcher that outlives its field would eat the next shortcut
            // someone pressed for a different reason.
            if recording { KeyCatcher.shared.start(handler: handle) } else { KeyCatcher.shared.stop() }
        }
        .onDisappear { KeyCatcher.shared.stop() }
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return shortcut?.displayString ?? "Off"
    }

    private var labelColor: Color {
        if isRecording { return .accentColor }
        return shortcut == nil ? .secondary : .primary
    }

    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        switch ShortcutRecording.outcome(keyCode: keyCode, modifiers: modifiers) {
        case let .commit(combination):
            if let owner = reserved[combination] {
                problem = "\(combination.displayString) is already \(owner)."
                return
            }
            shortcut = combination
            problem = nil
            isRecording = false
        case .clear:
            shortcut = nil
            problem = nil
            isRecording = false
        case .cancel:
            problem = nil
            isRecording = false
        case let .reject(reason):
            problem = reason
        }
    }
}

/// Catches the next key press for whoever is recording.
///
/// A local monitor, not a global one: recording happens in a window the person
/// is looking at, so the keys are already coming to this app. It also returns
/// `nil` — the one place in this app that swallows a key — because the whole
/// point is that ⌘W records rather than closes the window.
@MainActor
private final class KeyCatcher {
    static let shared = KeyCatcher()

    private var monitor: Any?

    func start(handler: @escaping (UInt16, NSEvent.ModifierFlags) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handler(event.keyCode, event.modifierFlags)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
