import DictationCore
import SwiftUI

struct MenuBarLabel: View {
    let state: DictationState
    let isDictationReady: Bool
    let hasRecoveredWork: Bool
    let successfulInsertionCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSuccess = false

    var body: some View {
        let activity = MenuBarStatus.activity(
            state: state,
            showsSuccess: showsSuccess
        )

        Group {
            if activity == .recording, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: false)) { timeline in
                    icon(activity: activity, opacity: pulseOpacity(at: timeline.date))
                }
            } else {
                icon(activity: activity, opacity: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            MenuBarStatus.accessibilityLabel(
                state: state,
                isDictationReady: isDictationReady,
                hasRecoveredWork: hasRecoveredWork,
                showsSuccess: showsSuccess
            )
        )
        .task(id: successfulInsertionCount) {
            guard successfulInsertionCount > 0 else { return }
            showsSuccess = true
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            showsSuccess = false
        }
    }

    private func icon(activity: MenuBarActivity, opacity: Double) -> some View {
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
                    .fill(color(for: activity))
                    .frame(width: 5, height: 5)
                    .opacity(opacity)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func color(for activity: MenuBarActivity) -> Color {
        switch activity {
        case .recording, .processing: return .blue
        case .success: return .green
        case .hidden: return .clear
        }
    }

    private func pulseOpacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate * 2 * Double.pi / 1.2
        return 0.35 + 0.65 * ((sin(phase) + 1) / 2)
    }
}
