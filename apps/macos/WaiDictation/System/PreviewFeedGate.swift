import Foundation
import os

/// Кран между аудиопотоком и предпросмотром распознавания.
///
/// Колбэк захвата приходит вне главного актора и не может заглянуть в
/// настройку `@Published showLivePreview`. Затвор — общая точка правды:
/// главный актор открывает и закрывает, аудиопуть только читает. Закрытый
/// затвор экономит задачу на каждый кадр (~23 в секунду) и гарантирует, что
/// в выключенный предпросмотр не уходит ни одного отсчёта.
final class PreviewFeedGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isOpen: Bool {
        state.withLock { $0 }
    }

    func open() {
        state.withLock { $0 = true }
    }

    func close() {
        state.withLock { $0 = false }
    }
}
