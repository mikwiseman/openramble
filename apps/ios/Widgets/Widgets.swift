import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct OpenRambleWidgets: WidgetBundle {
    var body: some Widget {
        DictationLiveActivity()
        DictateControl()
    }
}

/// One tap from Control Center, the Lock Screen or the Action button: record a
/// take without opening the app.
struct DictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "is.waiwai.dictation.dictate") {
            ControlWidgetButton(action: DictateIntent()) {
                Label("Dictate", systemImage: "waveform")
            }
        }
        .displayName("Dictate")
        .description("Record a take. The words are written on this iPhone and copied.")
    }
}

private let red = Color(red: 1, green: 0.231, blue: 0.188)

/// The take while it is recorded and written.
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            LockScreenTake(state: context.state)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StageMark(stage: context.state.stage)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(state: context.state)
                        .font(.title3.monospacedDigit())
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(Self.headline(context.state))
                            .font(.headline.weight(.regular))
                        Spacer()
                        if context.state.stage == .listening {
                            Button(intent: StopDictationIntent()) {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.subheadline.weight(.medium))
                            }
                            .tint(red)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                StageMark(stage: context.state.stage)
            } compactTrailing: {
                Elapsed(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                StageMark(stage: context.state.stage)
            }
            .keylineTint(red)
        }
    }

    static func headline(_ state: DictationActivityAttributes.ContentState) -> String {
        switch state.stage {
        case .listening: "Listening"
        case .writing: "Writing"
        case .written:
            state.copied ? "Written and copied" : "Written"
        case .failed: "Not written. Open OpenRamble to try again."
        }
    }
}

private struct LockScreenTake: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            StageMark(stage: state.stage)
            VStack(alignment: .leading, spacing: 2) {
                Text(DictationLiveActivity.headline(state))
                    .font(.system(.title3, design: .serif))
                if let words = state.wordCount, state.stage == .written {
                    Text(words == 1 ? "1 word" : "\(words) words")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Elapsed(state: state)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
            if state.stage == .listening {
                Button(intent: StopDictationIntent()) {
                    Image(systemName: "stop.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(red, in: .circle)
                .accessibilityLabel("Stop")
            }
        }
    }
}

private struct StageMark: View {
    let stage: DictationActivityAttributes.ContentState.Stage

    var body: some View {
        switch stage {
        case .listening:
            Circle().fill(red).frame(width: 12, height: 12)
                .accessibilityLabel("Recording")
        case .writing:
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative)
                .accessibilityLabel("Writing")
        case .written:
            Image(systemName: "checkmark")
                .accessibilityLabel("Written")
        case .failed:
            Image(systemName: "exclamationmark")
                .accessibilityLabel("Not written")
        }
    }
}

/// The running time while listening (the system counts it, no updates
/// needed), the take's length afterwards.
private struct Elapsed: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        if state.stage == .listening {
            Text(timerInterval: state.startedAt...state.startedAt.addingTimeInterval(24 * 3600), countsDown: false)
                .multilineTextAlignment(.trailing)
        } else if let duration = state.duration {
            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
        }
    }
}
