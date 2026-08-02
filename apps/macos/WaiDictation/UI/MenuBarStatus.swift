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
        case .listening: return "Wai Dictation: идёт запись"
        case .transcribing: return "Wai Dictation: распознаю речь"
        case .inserting: return "Wai Dictation: вставляю текст"
        case .preparing: return "Wai Dictation: включаю микрофон"
        case .idle:
            return isDictationReady
                ? "Wai Dictation: готово к диктовке"
                : "Wai Dictation: нужна настройка"
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
                ? "Удерживайте \(hotkeyTitle) и говорите"
                : "Нужна настройка"
        case .preparing: return "Включаю микрофон…"
        case .listening:
            // В режиме без удержания клавишу отпускают, а запись продолжается.
            // Не сказать об этом — значит оставить человека с включённым
            // микрофоном и уверенностью, что он уже выключен.
            return isHandsFreeActive
                ? "Слушаю — нажмите \(hotkeyTitle), чтобы закончить"
                : "Слушаю"
        case .transcribing: return "Распознаю…"
        case .inserting: return "Вставляю текст"
        }
    }
}
