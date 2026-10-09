import DictationCore
import SwiftUI

/// A reading column with sticky audio-source headings and explicit playback targets.
struct TranscriptView: View {
    let utterances: [MeetingUtterance]
    var currentTime: TimeInterval?
    var onSeek: ((TimeInterval) -> Void)?
    var followsLive = false

    @State private var follow = TranscriptFollowState()
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(TranscriptSection.make(utterances)) { section in
                        Section {
                            ForEach(section.utterances) { utterance in
                                TranscriptTurnView(
                                    utterance: utterance,
                                    isCurrent: isCurrent(utterance),
                                    onTap: onSeek.map { seek in { seek(utterance.start) } }
                                )
                                .id(utterance.id)
                            }
                        } header: {
                            HStack(spacing: GlassTokens.Space.inline) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(section.channel == .microphone ? Color.accentColor : .secondary)
                                    .frame(width: 3, height: 12)
                                    .accessibilityHidden(true)
                                Text(MeetingTranscriptFormatter.defaultNames[section.channel] ?? section.channel.rawValue)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, GlassTokens.Space.inline)
                            .padding(.horizontal, GlassTokens.Space.inline)
                            .background(.background)
                        }
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: 748)
                .padding(.horizontal, GlassTokens.Space.section)
                .padding(.vertical, GlassTokens.Space.inline)
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                    }
                }
            }
            .background(.background)
            .onPreferenceChange(TranscriptHeightKey.self) { contentHeight = $0 }
            .modifier(TranscriptScrollTracking { distance in
                if followsLive { follow.userScrolled(distanceFromBottom: distance) }
            })
            .overlay(alignment: .bottom) {
                if followsLive && !follow.followsLatest {
                    Button {
                        follow.returnToLatest()
                        withAnimation(reduceMotion ? nil : .easeOut(duration: GlassTokens.Motion.surfaceChange)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    } label: {
                        Label(L10n.tr("Jump to Latest"), systemImage: "arrow.down")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, GlassTokens.Space.stack)
                            .padding(.vertical, GlassTokens.Space.inline)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(Capsule())
                    .padding(.bottom, GlassTokens.Space.inline)
                }
            }
            .onAppear {
                if followsLive { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: utterances) { _, _ in
                if followsLive && follow.followsLatest {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: contentHeight) { _, _ in
                // Lazy paragraph heights settle after the utterance update. Follow the laid-out bottom too.
                if followsLive && follow.followsLatest { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    private func isCurrent(_ utterance: MeetingUtterance) -> Bool {
        guard let currentTime else { return false }
        return currentTime >= utterance.start && currentTime < utterance.end
    }
}

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
        HStack(alignment: .firstTextBaseline, spacing: GlassTokens.Space.stack) {
            Group {
                if let onTap {
                    Button(action: onTap) { timestamp }
                        .buttonStyle(.plain)
                        .help(L10n.tr("Play from ") + RecordingTime.clock(utterance.start))
                        .accessibilityLabel(L10n.tr("Play from ") + RecordingTime.spoken(utterance.start))
                } else {
                    timestamp
                }
            }
            .frame(minWidth: 44, alignment: .trailing)
            Group {
                if utterance.isFailed {
                    Text(L10n.tr("Couldn't transcribe this part"))
                        .italic()
                        .foregroundStyle(StatusColorRole.attention.color)
                } else {
                    Text(utterance.text)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 15))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(speaker + ": " + (utterance.isFailed ? L10n.tr("Couldn't transcribe this part") : utterance.text))
        }
        .padding(.vertical, GlassTokens.Space.inline)
        .padding(.horizontal, GlassTokens.Space.inline)
        .background(
            isCurrent ? Color.accentColor.opacity(contrast == .increased ? 0.3 : 0.10) : .clear,
            in: RoundedRectangle(cornerRadius: GlassTokens.Radius.chip, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var timestamp: some View {
        Text(RecordingTime.clock(utterance.start))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// How far behind a live decode may get before the line is worth saying.
///
/// Ten seconds hid the first wait entirely: a segment is only queued after
/// a pause, so the backlog sat at zero until the first paragraph landed.
enum TranscriptStatusPolicy {
    static let backlogVisibleAfter: TimeInterval = 3
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
                    Button(L10n.tr("Retry")) { state.resumeTranscription() }
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
            return ("exclamationmark.triangle.fill", .attention, L10n.tr("Transcription paused."))
        }
        if !state.isEngineReady {
            return ("clock", .processing, L10n.tr("Waiting for the speech model."))
        }
        if state.dictationState != .idle {
            return ("waveform", .processing, L10n.tr("Transcription paused while you dictate."))
        }
        if state.transcriptBacklogSeconds >= TranscriptStatusPolicy.backlogVisibleAfter {
            return ("waveform", .processing, L10n.tr("Transcribing — about %@ seconds behind.", String(describing: Int(state.transcriptBacklogSeconds.rounded()))))
        }
        return nil
    }
}
