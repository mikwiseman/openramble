# Wai Dictation — правила репозитория

Локальная диктовка для macOS. Нажал клавишу → сказал → отпустил → текст в активном приложении.

## Главное правило: сеть

Разрешены **ровно две** сетевые операции, обе явные и обе инициированы пользователем:
1. Скачивание модели по кнопке (`LocalASR/ModelStore`).
2. Проверка обновлений Sparkle (выключена, пока пользователь не включит).

Всё остальное — нарушение. Сетевые символы допустимы только в
`LocalASR/ModelDownloading.swift` и `SparkleUpdater.swift`. Полный список того,
что запрещено вне этих двух файлов, — в `scripts/check-network-surface.sh`:
кроме очевидных `URLSession`/`NWConnection`/`CFNetwork`/`WKWebView` туда входят
`Data(contentsOf:)`, `String(contentsOf:)`, `NSAttributedString(url:)`,
`NSImage(contentsOf:)`, `AVAsset(url:)`, `SFSpeechRecognizer`,
`NSUbiquitousKeyValueStore`, `CKContainer`/`CKDatabase`, `MLModelCollection`.
Это проверяется в CI. Меняете список — меняйте и обещание в `README.md`.

## Архитектурные границы

- **`DictationCore`** — чистая логика, без AppKit и без ML. Здесь живёт `DictationController`
  и протокол `ASREngineAdapting`. Края приложения (вставка текста, оверлей, звук, захват) —
  за протоколами, чтобы тесты шли через быстрый `swift test`.
- **`LocalASR`** зависит от `DictationCore`, не наоборот. `import FluidAudio` разрешён
  ровно в одном файле — `FluidAudioAdapter.swift`.
- **`apps/macos`** — тонкий слой: SwiftUI, AppKit, реализации протоколов.

## Приватность в коде

- Никогда не логировать текст диктовки, отдельные слова или имена файлов пользователя.
  `privacy: .public` допустим только для чисел и имён состояний.
- Буфер обмена пишется **только** через `prepareForNewContents(with: .currentHostOnly)`
  плюс маркеры transient/concealed. Голый `clearContents()` запрещён — он отдаёт диктовку
  в Universal Clipboard на все устройства Apple ID.
- Никакой телеметрии, аналитики и сторонних SDK.

## Релиз

- Идентификатор `is.waiwai.dictation` неизменен навсегда: к нему привязан
  выданный универсальный доступ. `scripts/build-dmg.sh` это проверяет.
- Вложенный код Sparkle подписывается по одному, изнутри наружу. `--deep` при
  подписи запрещён (теряет entitlements у `Downloader.xpc` и ломает установку
  обновления), при проверке — нужен. Подробности: `docs/release.md`.

## Работа

- TDD: сначала падающий тест, потом код.
- Политики и решения — чистые типы (`enum`/`struct`) с тестами, а не логика внутри вью-моделей.
- Ошибки видимы пользователю. Молчаливая деградация запрещена.
- Перед коммитом: `swift test` в обоих пакетах.
