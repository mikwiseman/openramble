import SwiftUI

/// Блок про модель — один и тот же в онбординге и в настройках.
///
/// Всё, что здесь видно, приходит готовым из `ModelStatus`: вью только рисует.
struct ModelStatusView: View {
    let status: ModelStatus
    let install: () -> Void
    let delete: () -> Void
    var announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer()

    /// Что уже сказано вслух. Доля загрузки меняется десятки раз в секунду —
    /// без этой памяти VoiceOver забил бы собой всё остальное.
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
                        // Уже прочитано как значение индикатора — второй раз не надо.
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
        // Установка модели — единственное место, где человек ждёт минутами.
        // Незрячему без объявлений остаётся молчащее окно: индикатор он не
        // видит, а под фокусом ничего не меняется.
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
                .foregroundStyle(.green)
        case .failure:
            Label(status.title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .neutral:
            Text(status.title)
        }
    }

    @ViewBuilder
    private func button(for action: ModelStatus.Action) -> some View {
        switch action {
        case .install:
            Button(action.title, action: install)
                .buttonStyle(.borderedProminent)
                .accessibilityHint(action.hint)
        case .retry:
            Button(action.title, action: install)
                .accessibilityHint(action.hint)
        case .delete:
            Button(action.title, role: .destructive, action: delete)
                .accessibilityHint(action.hint)
        }
    }
}
