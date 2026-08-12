import SwiftUI

/// The block about the model is the same in onboarding and in settings.
///
/// Everything that is visible here comes ready from `ModelStatus`: the view only draws.
struct ModelStatusView: View {
    let status: ModelStatus
    let install: () -> Void
    let cancel: () -> Void
    let delete: () -> Void
    var announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer()

    /// What has already been said out loud. The load share changes dozens of times per second -
    /// Without this memory, VoiceOver would have overwhelmed everything else.
    @State private var announced: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title

            if let progress = status.progress {
                ProgressView(value: progress)
                    .accessibilityLabel(status.title)
                    .accessibilityValue(status.progressLabel ?? "")
                if let label = status.progressLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // Already read as an indicator value - no need for a second time.
                        .accessibilityHidden(true)
                }
            }

            if let detail = status.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(status.actions, id: \.self) { action in
                button(for: action)
            }
        }
        // Model installation is the only place where a person waits for minutes.
        // The blind person is left with a silent window without announcements: the indicator is not
        // sees, but nothing changes under focus.
        .onChange(of: status.announcement, initial: true) { _, announcement in
            guard announced != announcement else { return }
            announced = announcement
            announcer.announce(announcement, urgent: status.tone == .failure)
        }
    }

    @ViewBuilder
    private var title: some View {
        switch status.tone {
        case .success:
            Label(status.title, systemImage: "checkmark.circle.fill")
                .foregroundStyle(StatusColorRole.success.color)
        case .failure:
            // Attention, not destructive red: the model's failures are all
            // recoverable with the button right below.
            Label(status.title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(StatusColorRole.attention.color)
        case .neutral:
            Text(status.title)
        }
    }

    @ViewBuilder
    private func button(for action: ModelStatus.Action) -> some View {
        switch action {
        case .install:
            Button(status.title(for: action), action: install)
                .buttonStyle(.borderedProminent)
                .accessibilityHint(status.hint(for: action))
        case .retry, .repair:
            Button(status.title(for: action), action: install)
                .accessibilityHint(status.hint(for: action))
        case .cancel:
            Button(status.title(for: action), role: .cancel, action: cancel)
                .accessibilityHint(status.hint(for: action))
        case .delete:
            Button(status.title(for: action), role: .destructive, action: delete)
                .accessibilityHint(status.hint(for: action))
        }
    }
}
