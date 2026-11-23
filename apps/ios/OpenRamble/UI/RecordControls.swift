import SwiftUI

/// The record button: one piece of Liquid Glass with a red mark in it. While
/// recording it becomes Stop, and two smaller pieces flow out of it: Discard on
/// the left, the running time on the right.
struct RecordControls: View {
    @Environment(Dictation.self) private var dictation
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 22) {
            HStack(spacing: 22) {
                if case .recording = dictation.phase {
                    Button {
                        dictation.discard()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, height: 56)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("discard", in: glass)
                    .accessibilityLabel("Discard")
                    .accessibilityHint("Stops recording and throws this take away.")
                }

                Button {
                    Task { await dictation.toggle() }
                } label: {
                    RecordMark(recording: dictation.isRecording)
                        .frame(width: 84, height: 84)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("record", in: glass)
                .disabled(dictation.phase == .starting)
                .accessibilityLabel(dictation.isRecording ? "Stop" : "Record")
                .accessibilityHint(dictation.isRecording ? "Stops recording and writes your words." : "Starts listening.")

                if case let .recording(since) = dictation.phase {
                    Text(timerInterval: since...since.addingTimeInterval(24 * 3600), countsDown: false)
                        .font(.subheadline.monospacedDigit())
                        // It lives inside a 56-point circle; past this size
                        // the time is read from the Dynamic Island instead.
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .circle)
                        .glassEffectID("time", in: glass)
                        .accessibilityLabel("Recording time")
                }
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.25), value: dictation.isRecording)
    }
}

/// Red dot to record, red square to stop: the one red thing in the app.
struct RecordMark: View {
    let recording: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: recording ? 7 : 15, style: .continuous)
            .fill(Theme.recording)
            .frame(width: recording ? 24 : 30, height: recording ? 24 : 30)
            .animation(.spring(duration: 0.35, bounce: 0.3), value: recording)
    }
}

/// The voice while it speaks: thin bars, newest on the right, older ones fading.
struct VoiceView: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let gap: CGFloat = 3
            let width = max(1, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            for (index, level) in levels.enumerated() {
                let height = max(width, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap),
                    y: (size.height - height) / 2,
                    width: width,
                    height: height
                )
                let age = Double(index + 1) / Double(count)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(.primary.opacity(0.18 + 0.82 * age))
                )
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Listening")
    }
}

/// A short word above the button: "Copied", or what went wrong.
struct NoticeView: View {
    @Environment(Dictation.self) private var dictation
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            if let notice = dictation.notice {
                content(notice)
                    .font(.subheadline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.blurReplace.combined(with: .offset(y: 8)))
                    .id(notice)
            }
        }
        .padding(.horizontal, Theme.margin)
        .animation(.smooth(duration: 0.35), value: dictation.notice)
    }

    @ViewBuilder private func content(_ notice: Dictation.Notice) -> some View {
        switch notice {
        case .copied:
            Label("Copied", systemImage: "checkmark")
        case .microphoneDenied:
            HStack(spacing: 14) {
                Text("OpenRamble can't hear you.")
                Button("Allow") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    dictation.dismissNotice()
                }
                .fontWeight(.medium)
            }
        case let .message(text):
            Text(text)
                .multilineTextAlignment(.center)
        }
    }
}

