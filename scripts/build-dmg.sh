#!/bin/bash
# Собрать образ для распространения.
#
# Без подписи получается «пробный» образ: он запускается только на этой машине
# и годится для проверки, а не для раздачи. Настоящий релиз требует сертификата
# Developer ID и нотаризации — переменные ниже.
#
#   DEVELOPER_ID   — «Developer ID Application: …»
#   NOTARY_PROFILE — профиль notarytool, заведённый через `xcrun notarytool store-credentials`
#
# Запуск:
#   ./scripts/build-dmg.sh            пробная сборка
#   DEVELOPER_ID="…" NOTARY_PROFILE="…" ./scripts/build-dmg.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Wai Dictation"
SCHEME="WaiDictation"
PROJECT="apps/macos/WaiDictation.xcodeproj"
BUILD_DIR="artifacts/build"
DMG_DIR="artifacts/dmg"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "→ Генерирую проект"
(cd apps/macos && xcodegen generate >/dev/null)

echo "→ Собираю релизную версию"
rm -rf "$BUILD_DIR" "$DMG_DIR"
mkdir -p "$BUILD_DIR" "$DMG_DIR"

if [[ -n "$DEVELOPER_ID" ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual)
else
  echo "  ВНИМАНИЕ: сертификат не задан — образ будет пробным"
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
  -destination 'generic/platform=macOS' \
  "${SIGN_ARGS[@]}" \
  | grep -E "error:|warning: .*deprecated|ARCHIVE" || true

APP_PATH="$BUILD_DIR/$SCHEME.xcarchive/Products/Applications/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Сборка не дала приложения" >&2
  exit 1
fi

# Обе архитектуры обязаны присутствовать: распознавание работает только на
# Apple Silicon, но запускаться приложение должно и на Intel, чтобы честно
# сказать об этом пользователю.
echo "→ Проверяю архитектуры"
ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")
echo "  $ARCHS"
for required in arm64 x86_64; do
  if [[ "$ARCHS" != *"$required"* ]]; then
    echo "  ВНИМАНИЕ: нет среза $required"
  fi
done

echo "→ Проверяю минимальную версию системы"
MIN_OS=$(vtool -show-build "$APP_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null | grep -m1 "minos" | awk '{print $2}')
echo "  minos $MIN_OS"
if [[ "$MIN_OS" != "14.0" ]]; then
  echo "  ВНИМАНИЕ: ожидалась 14.0" >&2
fi

if [[ -n "$DEVELOPER_ID" ]]; then
  echo "→ Подписываю"
  codesign --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

echo "→ Собираю образ"
STAGING="$DMG_DIR/staging"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

VERSION=$(defaults read "$(pwd)/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
DMG_PATH="$DMG_DIR/WaiDictation-$VERSION.dmg"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

if [[ -n "$DEVELOPER_ID" && -n "$NOTARY_PROFILE" ]]; then
  echo "→ Отправляю на нотаризацию (это занимает несколько минут)"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  echo "→ Нотаризовано"
else
  echo "  Нотаризация пропущена: образ запустится только на этой машине"
fi

shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"
echo ""
echo "Готово: $DMG_PATH"
