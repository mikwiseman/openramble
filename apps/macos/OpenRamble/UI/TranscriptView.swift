import DictationCore
import SwiftUI

/// The transcript as paragraphs, one full-measure column.
///
/// Not two lanes — at 400 pt each is below a comfortable measure and one side
/// talking for three minutes leaves the other ragged and empty. Not bubbles —
/// this is a document to read, search and export, not a chat to be in. Each
/// paragraph carries its speaker in a gutter, and the person's own turns get
/// a rail on the leading edge: a positional cue, so the two sides stay
/// distinguishable in greyscale and under Increase Contrast.
struct TranscriptView: View {
    let utterances: [MeetingUtterance]
    var currentTime: TimeInterval?
    var onSeek: ((TimeInterval) -> Void)?

    private var ordered: [MeetingUtterance] {
        utterances.sorted { $0.start < $1.start }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: GlassTokens.Space.tight) {
                ForEach(ordered) { utterance in
                    TranscriptTurnView(
                        utterance: utterance,
                        isCurrent: isCurrent(utterance),
                        onTap: onSeek.map { seek in { seek(utterance.start) } }
                    )
                }
            }
            .padding(.horizontal, GlassTokens.Space.page)
            .padding(.vertical, GlassTokens.Space.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isCurrent(_ utterance: MeetingUtterance) -> Bool {
        guard let currentTime else { return false }
        return currentTime >= utterance.start && currentTime < utterance.end
    }
}

struct TranscriptTurnView: View {
    let utterance: MeetingUtterance
    let isCurrent: Bool
    var onTap: (() -> Void)?

    @Environment(\.colorSchemeContrast) private var contrast

    private var speaker: String {
        MeetingTranscriptFormatter.defaultNames[utterance.channel] ?? utterance.channel.rawValue
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: GlassTokens.Space.inline) {
            Text(speaker)
                .font(.system(size: GlassTokens.Label.sectionHeader, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Group {
                if utterance.isFailed {
                    Text("Couldn't transcribe this part")
                        .italic()
                        .foregroundStyle(StatusColorRole.attention.color)
                } else {
                    Text(utterance.text)
                        .textSelection(.enabled)
                }
            }
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(RecordingTime.clock(utterance.start))
                .font(.system(size: GlassTokens.Label.footnote))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, GlassTokens.Space.tight)
        .padding(.horizontal, GlassTokens.Space.inline)
        .overlay(alignment: .leading) {
            if utterance.channel == .microphone {
                RoundedRectangle(cornerRadius: 1)
                    .fill(contrast == .increased ? Color.primary.opacity(0.42) : Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, GlassTokens.Space.tight)
            }
        }
        .background(
            isCurrent ? Color.accentColor.opacity(contrast == .increased ? 0.3 : 0.12) : .clear,
            in: RoundedRectangle(cornerRadius: GlassTokens.Radius.chip, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speaker)
        .accessibilityValue(utterance.isFailed ? "Couldn't transcribe this part" : utterance.text)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAction(named: "Play from here") { onTap?() }
    }
}

/// One honest line under the live transcript about how far behind it is —
/// and nothing at all when it is not worth saying.
///
/// Orange for a stopped transcription, never red: red is a live microphone,
/// and every state here is recoverable — the audio is safe.
struct TranscriptStatusLine: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let line {
            HStack(spacing: GlassTokens.Space.inline) {
                Image(systemName: line.symbol)
                    .foregroundStyle(line.role.color)
                    .accessibilityHidden(true)
                Text(line.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.isTranscriptionPaused {
                    Spacer(minLength: GlassTokens.Space.inline)
                    Button("Retry") { state.resumeTranscription() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, GlassTokens.Space.page)
            .padding(.vertical, GlassTokens.Space.inline)
            .accessibilityElement(children: .contain)
        }
    }

    private var line: (symbol: String, role: StatusColorRole, text: String)? {
        if state.isTranscriptionPaused {
            return ("exclamationmark.triangle.fill", .attention, "Transcription stopped. The recording is still running.")
        }
        if !state.isEngineReady {
            return ("clock", .processing, "Waiting for the speech model. The recording is still running.")
        }
        if state.dictationState != .idle {
            return ("waveform", .processing, "Paused for dictation. The recording is still running.")
        }
        if state.transcriptBacklogSeconds >= 10 {
            return ("waveform", .processing, "Transcribing — about \(Int(state.transcriptBacklogSeconds.rounded())) seconds behind.")
        }
        return nil
    }
}
