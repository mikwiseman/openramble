import SwiftUI

/// The small arrow that puts one setting back the way it came.
///
/// Per setting rather than one "reset everything" button, because those are
/// different promises. A person who wants the dictation key back does not want
/// their dictionary emptied, and a single button that does both is a button
/// nobody dares press. This one is also its own answer to "what did I change
/// here?" — the arrow is only live where the value differs from the default.
struct RevertToDefault: View {
    let isChanged: Bool
    let revert: () -> Void

    var body: some View {
        Button(action: revert) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .disabled(!isChanged)
        // Kept in the layout rather than removed when inactive: a control that
        // appears and disappears makes every row jump as settings change.
        .opacity(isChanged ? 1 : 0)
        .accessibilityLabel("Reset to default")
        .accessibilityHidden(!isChanged)
        .help("Reset to default")
    }
}

/// One settings row: a name, its control, and the arrow that undoes it.
struct SettingRow<Control: View>: View {
    let title: String
    let isChanged: Bool
    let revert: () -> Void
    @ViewBuilder var control: () -> Control

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                control()
                RevertToDefault(isChanged: isChanged, revert: revert)
            }
        } label: {
            Text(title)
        }
    }
}
