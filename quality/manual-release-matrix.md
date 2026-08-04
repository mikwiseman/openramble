# Safe beta manual release matrix

Заполняется для одного `HEAD SHA` и одного SHA-256 подписанного, notarized и
stapled DMG. Пустая обязательная строка блокирует release.
Итог продублируйте в локальной копии `release-evidence-template.json` — именно
её `release.sh` машинно сверяет с HEAD и байтами DMG.

| Среда | Сценарии | Результат | Evidence |
|---|---|---|---|
| M1, 8 GB, macOS 14 | onboarding; model download/cancel/retry; offline relaunch; built-in mic; hold/double-tap; focus/secure-input/clipboard race; Mic/Accessibility deny-grant-revoke; process kill recovery; sleep/wake | REQUIRED | |
| Current Apple Silicon, macOS 26 | те же сценарии; built-in + Bluetooth/USB disconnect | REQUIRED | |
| Apple Silicon, macOS 15 | тот же smoke при доступном окружении | OPTIONAL; отсутствие указать в beta notes | |
| Previous installed internal build → current DMG | Sparkle check, download, signature verification, install, relaunch, сохранение Accessibility | REQUIRED | |

## Artifact evidence

| Поле | Значение |
|---|---|
| Git SHA | |
| DMG path | |
| DMG SHA-256 | |
| `codesign --verify --deep --strict` | |
| `spctl --assess` | |
| `xcrun stapler validate` | |
| All Mach-O arm64, minOS 14.0 | |
| Runtime sandbox positive-control + zero-network | |
| Runtime tracer positive-control + zero DNS/connect/send | |
| Static network surface scan | |
| Package/app test totals | |

Позиционирование: `Russian-UI safe beta`; RU/EN final dictation локальна,
mixed RU/EN экспериментальна. Claims про 25 качественных языков, Typeless parity
или state-of-the-art до live comparative benchmark запрещены.
