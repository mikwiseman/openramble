import DictationCore

/// Значок в строке меню и то, что о нём говорят.
///
/// Значок — единственное постоянное присутствие приложения на экране. Картинка
/// без описания для незрячего человека не существует вовсе: VoiceOver прочитает
/// имя системного символа вроде «mic.slash» или промолчит.
enum MenuBarStatus {
    static func iconName(state: DictationState, isDictationReady: Bool) -> String {
        switch state {
        case .listening: return "mic.fill"
        case .transcribing, .inserting: return "waveform"
        case .preparing, .idle: return isDictationReady ? "mic" : "mic.slash"
        }
    }

    /// Ярлык значка. Начинается с имени приложения: в строке меню значков много,
    /// и «идёт запись» без хозяина ничего не говорит.
    static func accessibilityLabel(state: DictationState, isDictationReady: Bool) -> String {
        switch state {
        case .listening: return "Wai Dictation: recording"
        case .transcribing: return "Wai Dictation: transcribing speech"
        case .inserting: return "Wai Dictation: inserting text"
        case .preparing: return "Wai Dictation: turning on the microphone"
        case .idle:
            return isDictationReady
                ? "Wai Dictation: ready to dictate"
                : "Wai Dictation: setup needed"
        }
    }

    /// Первая строка меню — она же объяснение, что делать.
    static func statusLine(
        state: DictationState,
        isDictationReady: Bool,
        isHandsFreeActive: Bool,
        hotkeyTitle: String
    ) -> String {
        switch state {
        case .idle:
            return isDictationReady
                ? "Hold \(hotkeyTitle) and speak"
                : "Setup needed"
        case .preparing: return "Turning on the microphone…"
        case .listening:
            // В режиме без удержания клавишу отпускают, а запись продолжается.
            // Не сказать об этом — значит оставить человека с включённым
            // микрофоном и уверенностью, что он уже выключен.
            return isHandsFreeActive
                ? "Listening — press \(hotkeyTitle) to finish"
                : "Listening"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Inserting text"
        }
    }
}
