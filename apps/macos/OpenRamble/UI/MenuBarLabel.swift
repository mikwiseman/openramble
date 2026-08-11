import DictationCore
import SwiftUI

struct MenuBarLabel: View {
    let state: DictationState
    let isDictationReady: Bool
    let hasRecoveredWork: Bool

    var body: some View {
        let activity = MenuBarStatus.activity(state: state)

        icon(activity: activity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            MenuBarStatus.accessibilityLabel(
                state: state,
                isDictationReady: isDictationReady,
                hasRecoveredWork: hasRecoveredWork
            )
        )
    }

    private func icon(activity: MenuBarActivity) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(
                MenuBarStatus.iconName(
                    state: state,
                    isDictationReady: isDictationReady,
                    hasRecoveredWork: hasRecoveredWork
                )
            )
            if activity != .hidden {
                Circle()
                    .fill(MenuBarStatus.color(activity: activity))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 22, height: 22)
    }
}
