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
            switch MenuBarStatus.badge(
                activity: activity,
                hasRecoveredWork: hasRecoveredWork
            ) {
            case .hidden:
                EmptyView()
            case .preparingRing:
                Circle()
                    .stroke(MenuBarStatus.color(activity: activity), lineWidth: 1.5)
                    .frame(width: 7, height: 7)
            case .recordingDot:
                Circle()
                    .fill(MenuBarStatus.color(activity: activity))
                    .frame(width: 6, height: 6)
            case .processingBar:
                Capsule()
                    .fill(MenuBarStatus.color(activity: activity))
                    .frame(width: 8, height: 3)
            case .recoveryWarning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 22, height: 22)
    }
}
