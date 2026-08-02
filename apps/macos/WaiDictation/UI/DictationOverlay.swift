import AppKit
import DictationCore
import SwiftUI

/// Небольшая панель, показывающая, что происходит с диктовкой.
///
/// Панель не забирает фокус: пользователь диктует в другое приложение, и увод
/// фокуса сломал бы вставку. Плата за это — панель не достаётся VoiceOver сама
/// собой, поэтому каждое изменение состояния ещё и объявляется вслух. Это не
/// украшение: своего окна у приложения нет, и другого способа узнать, что
/// микрофон включён, у незрячего человека тоже нет.
@MainActor
public final class DictationOverlay: OverlayPresenting {
    private var panel: NSPanel?
    private let model: OverlayModel

    public init(
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        noticeDuration: Duration = .seconds(4)
    ) {
        model = OverlayModel(announcer: announcer, noticeDuration: noticeDuration)
        model.onVisibilityChange = { [weak self] visible in
            if visible {
                self?.showPanel()
            } else {
                self?.hidePanel()
            }
        }
    }

    nonisolated public func present(_ state: DictationState, elapsed: TimeInterval) async {
        await MainActor.run { model.show(state, elapsed: elapsed) }
    }

    nonisolated public func dismiss() async {
        await MainActor.run { model.hide() }
    }

    nonisolated public func presentNotice(_ notice: DictationNotice) async {
        await MainActor.run { model.showNotice(notice) }
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

/// Состояние панели: что на ней написано, видна ли она и что уже сказано вслух.
///
/// Живёт отдельно от `NSPanel` намеренно. Окно требует графического сеанса, а
/// правила показа — счётчик секунд, автоскрытие сообщения, объявления для
/// VoiceOver — проверяются без него.
@MainActor
final class OverlayModel: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var notice: DictationNotice?

    /// Должна ли панель быть на экране. Показывает её владелец.
    private(set) var isVisible = false
    var onVisibilityChange: ((Bool) -> Void)?

    /// Идёт ли отсчёт секунд.
    var isTicking: Bool { timer != nil }

    var content: OverlayContent {
        OverlayContent.make(state: state, notice: notice, elapsed: elapsed)
    }

    private let announcer: any AccessibilityAnnouncing
    private let noticeDuration: Duration
    /// Помечен `nonisolated(unsafe)`, потому что таймер снимает `deinit`, а он у
    /// изолированного класса — вне изоляции. Трогают его только с главного
    /// потока: панель целиком живёт на нём.
    nonisolated(unsafe) private var timer: Timer?
    private var startedAt: Date?
    private var autoHide: Task<Void, Never>?
    /// Что уже сказано вслух. Счётчик секунд тикает дважды в секунду, и без
    /// этой памяти VoiceOver повторял бы «идёт запись» до конца диктовки.
    private var lastAnnouncement: String?

    init(
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        noticeDuration: Duration = .seconds(4)
    ) {
        self.announcer = announcer
        self.noticeDuration = noticeDuration
    }

    deinit {
        // Таймер, оставленный в цикле выполнения, продолжает будить процесс и
        // после смерти владельца.
        timer?.invalidate()
        autoHide?.cancel()
    }

    /// Показать состояние диктовки.
    func show(_ state: DictationState, elapsed: TimeInterval) {
        cancelAutoHide()
        self.state = state
        notice = nil
        setElapsed(elapsed, ticking: state == .listening)
        setVisible(true)
        announceContent()
    }

    /// Показать сообщение и убрать его через положенное время.
    func showNotice(_ notice: DictationNotice) {
        cancelAutoHide()
        setElapsed(elapsed, ticking: false)
        self.notice = notice
        setVisible(true)
        announceContent()

        let duration = noticeDuration
        autoHide = Task { [weak self] in
            try? await Task.sleep(for: duration)
            // Отложенное скрытие принадлежит своему показу. Проверка отмены
            // обязательна: `try?` глотает её вместе с ошибкой, и без неё
            // отменённая задача досыпает не до конца, а просыпается сразу — и
            // уносит с экрана уже следующее сообщение.
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
            self.setVisible(false)
        }
    }

    /// Убрать панель.
    ///
    /// Сообщение остаётся на экране: человек должен успеть его прочесть, а
    /// уборка после сессии приходит сразу за ним.
    func hide() {
        setElapsed(elapsed, ticking: false)
        guard notice == nil else { return }
        cancelAutoHide()
        setVisible(false)
        // Следующая диктовка обязана объявиться заново, даже если состояние
        // совпадает с прошлым.
        lastAnnouncement = nil
    }

    /// Показать прошедшее время.
    ///
    /// Пока идёт запись, счётчик ведёт сама панель. Иначе он показывал бы «0 с»
    /// всю диктовку: ядро сообщает о начале записи один раз и следующий раз
    /// выходит на связь уже после её конца — то есть ровно тогда, когда счётчик
    /// уже не нужен. Секунды здесь единственный признак, что запись правда идёт.
    private func setElapsed(_ value: TimeInterval, ticking: Bool) {
        elapsed = value

        guard ticking else {
            timer?.invalidate()
            timer = nil
            startedAt = nil
            return
        }

        guard timer == nil else { return }
        startedAt = Date().addingTimeInterval(-value)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// Отложенное скрытие прошлого показа больше не действует.
    private func cancelAutoHide() {
        autoHide?.cancel()
        autoHide = nil
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        onVisibilityChange?(visible)
    }

    private func announceContent() {
        let content = self.content
        guard let announcement = content.announcement, announcement != lastAnnouncement else { return }
        lastAnnouncement = announcement
        announcer.announce(announcement, urgent: content.isAnnouncementUrgent)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        let content = model.content

        return HStack(spacing: 12) {
            Circle()
                .fill(color(for: content.tone))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle = content.subtitle {
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
        // Панель читается одним элементом: цветная точка и счётчик по
        // отдельности не значат ничего.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }

    private func color(for tone: OverlayContent.Tone) -> Color {
        switch tone {
        case .idle: return .secondary
        case .recording: return .red
        case .working: return .blue
        case .info: return .blue
        case .warning: return .orange
        case .failure: return .red
        }
    }
}
