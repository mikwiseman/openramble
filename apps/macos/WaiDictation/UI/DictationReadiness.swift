import LocalASR

/// Почему нажатие клавиши сейчас ничего не начнёт.
///
/// Ядро отклоняет старт молча — и правильно делает: у него нет ни экрана, ни
/// слов. Но для человека молчание неотличимо от поломки. Больнее всего это в
/// окне прогрева сразу после установки: он только что всё сделал правильно,
/// жмёт клавишу, и не происходит ничего — ни звука, ни панели, ни объяснения.
///
/// Отдельным типом, а не ветками внутри `AppState`: набор причин проверяется
/// таблицей, а не нажатием живой клавиши на живом микрофоне.
enum DictationReadiness {
    /// `nil` — можно диктовать.
    ///
    /// Порядок совпадает с порядком онбординга: сначала разрешения, потом
    /// модель, потом прогрев. Человеку называется первое, что его держит, а не
    /// все три сразу — список из трёх пунктов в панели на четыре секунды не
    /// читается.
    static func reason(
        accessibilityGranted: Bool,
        microphoneGranted: Bool,
        modelState: ModelState,
        isEngineReady: Bool
    ) -> String? {
        guard accessibilityGranted else {
            return "Dictation needs Accessibility access. Open Settings → General → Permissions."
        }
        guard microphoneGranted else {
            return "Dictation needs microphone access. Open Settings → General → Permissions."
        }

        switch modelState {
        case .notInstalled:
            return "The recognition model isn't downloaded yet. Open Settings → Model."
        case .downloading:
            return "The recognition model is still downloading."
        case .verifying:
            return "The downloaded model is still being verified."
        case .deleting:
            return "The recognition model is being deleted."
        case .repairRequired, .failed:
            return "The recognition model needs repair. Open Settings → Model."
        case .ready:
            break
        }

        guard isEngineReady else {
            // Самый обидный случай: всё установлено, всё выдано, и всё равно
            // молчание. Называем срок — иначе непонятно, ждать секунду или
            // перезапускать приложение.
            return "The model is getting ready for this Mac — usually 20–40 seconds, and only once."
        }

        return nil
    }
}
