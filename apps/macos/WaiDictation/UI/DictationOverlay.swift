import AppKit
import DictationCore
import SwiftUI

/// Небольшая панель, показывающая, что происходит с диктовкой.
///
/// Панель не забирает фокус: пользователь диктует в другое приложение, и увод
/// фокуса сломал бы вставку.
@MainActor
public final class DictationOverlay: OverlayPresenting {
    private var panel: NSPanel?
    private let model = OverlayModel()

    public init() {}

    nonisolated public func present(_ state: DictationState, elapsed: TimeInterval) async {
        await MainActor.run {
            model.state = state
            model.elapsed = elapsed
            model.notice = nil
            showPanel()
        }
    }

    nonisolated public func dismiss() async {
        await MainActor.run {
            // Сообщение остаётся на экране: пользователь должен успеть его прочесть.
            guard model.notice == nil else { return }
            hidePanel()
        }
    }

    nonisolated public func presentNotice(_ notice: DictationNotice) async {
        await MainActor.run {
            model.notice = notice
            showPanel()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if model.notice == notice {
                    model.notice = nil
                    hidePanel()
                }
            }
        }
    }

    private func showPanel() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: OverlayView(model: model))
            self.panel = panel
        }
        position()
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    /// Показать панель на том экране, где сейчас работает пользователь.
    ///
    /// Позиция пересчитывается на каждый показ: за время между диктовками
    /// монитор могли отключить или мышь могла уехать на другой.
    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 24
            )
        )
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var notice: DictationNotice?
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 12) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var indicator: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var color: Color {
        if let notice = model.notice {
            switch notice.kind {
            case .info: return .blue
            case .warning: return .orange
            case .failure: return .red
            }
        }
        switch model.state {
        case .listening: return .red
        case .transcribing, .inserting: return .blue
        case .preparing, .idle: return .secondary
        }
    }

    private var title: String {
        if let notice = model.notice { return notice.message }
        switch model.state {
        case .idle: return "Готово"
        case .preparing: return "Включаю микрофон…"
        case .listening: return "Слушаю"
        case .transcribing: return "Распознаю…"
        case .inserting: return "Вставляю"
        }
    }

    private var subtitle: String? {
        guard model.notice == nil else { return nil }
        switch model.state {
        case .listening, .transcribing:
            return String(format: "%.0f с", model.elapsed)
        default:
            return nil
        }
    }
}
