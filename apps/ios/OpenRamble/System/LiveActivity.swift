import ActivityKit
import Foundation
import OpenRambleKit

/// The take on the Lock Screen and in the Dynamic Island: listening with a
/// running time and a Stop button, then writing, then "written and copied"
/// for a few seconds before it leaves.
///
/// Only the activity's id is kept: `Activity` is not `Sendable`, so each
/// change finds it again where it is applied.
@MainActor
final class LiveActivityController {
    typealias State = DictationActivityAttributes.ContentState
    private var activityID: String?
    private var startedAt = Date.now

    func listening(since start: Date) {
        startedAt = start
        let state = State(stage: .listening, startedAt: start, copied: false)
        if activityID != nil {
            update(state)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activityID = try? Activity.request(
            attributes: DictationActivityAttributes(),
            content: ActivityContent(state: state, staleDate: nil)
        ).id
    }

    func writing(duration: TimeInterval) {
        update(State(stage: .writing, startedAt: startedAt, duration: duration, copied: false))
    }

    func written(wordCount: Int, copied: Bool, duration: TimeInterval) {
        end(State(stage: .written, startedAt: startedAt, duration: duration, wordCount: wordCount, copied: copied),
            after: 4)
    }

    func failed(duration: TimeInterval) {
        end(State(stage: .failed, startedAt: startedAt, duration: duration, copied: false), after: 6)
    }

    /// The take was discarded: nothing to say.
    func cancel() {
        guard let id = activityID else { return }
        activityID = nil
        Task.detached { await Self.find(id)?.end(nil, dismissalPolicy: .immediate) }
    }

    private func update(_ state: State) {
        guard let id = activityID else { return }
        Task.detached { await Self.find(id)?.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func end(_ state: State, after seconds: TimeInterval) {
        guard let id = activityID else { return }
        activityID = nil
        Task.detached {
            await Self.find(id)?.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(.now.addingTimeInterval(seconds))
            )
        }
    }

    private nonisolated static func find(_ id: String) -> Activity<DictationActivityAttributes>? {
        Activity<DictationActivityAttributes>.activities.first { $0.id == id }
    }
}
