import SwiftUI

/// The honesty strip: one card, shown only while the other side is not
/// arriving as it should, with the one or two things that could fix it.
///
/// Content material, never glass — it sits inside content. Orange, never
/// red: the audio is safe, half of it is missing, and a change of output or
/// a relaunch can still fix the rest of the meeting.
struct CaptureHealthStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let title = state.liveCaptureHealth.title {
            VStack(alignment: .leading, spacing: GlassTokens.Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: GlassTokens.Space.inline) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StatusColorRole.attention.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.callout.weight(.medium))
                        if let detail = state.liveCaptureHealth.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if case .unheard = state.liveCaptureHealth {
                    HStack(spacing: GlassTokens.Space.inline) {
                        Button("Open System Settings") { state.openSystemAudioSettings() }
                        Button("Relaunch OpenRamble") { state.relaunchForSystemAudio() }
                            .disabled(state.isRecordingInProgress)
                            .help(state.isRecordingInProgress
                                ? "Finish the current recording first — relaunching now would end it."
                                : "Relaunch so macOS applies the permission to the new process")
                    }
                    .controlSize(.small)
                    if state.isRecordingInProgress {
                        // A dead button without a reason is where setup ends
                        // for a blind person.
                        Text("Finish the current recording first — relaunching now would end it.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(GlassTokens.Space.stack)
            .contentSurface(RoundedRectangle(cornerRadius: GlassTokens.Radius.control, style: .continuous))
            .padding(.horizontal, GlassTokens.Space.page)
            .padding(.top, GlassTokens.Space.stack)
            .accessibilityElement(children: .contain)
        }
    }
}

/// The one-time explanation before the first recording that captures the
/// other side. The system prompt follows it; this is what the prompt cannot
/// say — what is recorded, where it stays, and that nobody else is told.
struct SystemAudioIntroSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: GlassTokens.Space.stack) {
            Text("Record the other side too?")
                .font(.title2.weight(.semibold))
            Text("OpenRamble can record what you hear — the other people in a call, or anything playing on this Mac — alongside your microphone. macOS will ask for permission the first time.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Everything stays on this Mac. Nothing is uploaded, and no other app is told you are recording. In many places recording a conversation without everyone's consent is illegal; asking is your responsibility.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { state.dismissSystemAudioIntro() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Record My Voice Only") { state.confirmSystemAudioIntro(includeSystemAudio: false) }
                Button("Record You and Others") { state.confirmSystemAudioIntro(includeSystemAudio: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, GlassTokens.Space.tight)
        }
        .padding(GlassTokens.Space.page)
        .frame(width: 460)
    }
}
