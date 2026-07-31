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
# Менять нельзя никогда: универсальный доступ выдан именно этому идентификатору,
# и с новым приложение после обновления окажется без разрешения.
BUNDLE_ID="is.waiwai.dictation"
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

# Идентификатор приложения обязан остаться неизменным навсегда: на нём держится
# выданный пользователем универсальный доступ. Сменится идентификатор — человек
# после обновления обнаружит, что диктовка молчит, и пойдёт выдавать разрешение
# заново. Проверяем до подписи, потому что подпись его и закрепляет.
echo "→ Проверяю идентификатор"
ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
echo "  $ACTUAL_BUNDLE_ID"
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Идентификатор не тот: ожидался $BUNDLE_ID, получился «$ACTUAL_BUNDLE_ID»." >&2
  echo "Скорее всего собралась конфигурация Debug (там суффикс .dev)." >&2
  exit 1
fi

if [[ -n "$DEVELOPER_ID" ]]; then
  echo "→ Подписываю"

  # Подписывать нужно изнутри наружу, каждый вложенный компонент отдельно.
  # Порядок и состав — из документации Sparkle (sparkle-project.org, раздел
  # про песочницу и подпись компонентов).
  #
  # --deep здесь запрещён по двум причинам. Apple объявила его для подписи
  # устаревшим («for emergency use only»): он применяет одни и те же опции ко
  # всему вложенному коду, хотя тот подписывается по-разному. Sparkle просит не
  # применять его прямо: Downloader.xpc подписывается со своими entitlements,
  # которых нет у остальных двоичных файлов, и одинаковыми опциями их не
  # накрыть. Ломается при этом не сборка и не нотаризация, а установка
  # обновления — то есть у первого же пользователя, и чинить будет уже нечем.
  SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  SPARKLE_VERSION="$SPARKLE/Versions/B"

  sign() {
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"
  }

  # Если Sparkle переедет на другую букву версии или уберёт компонент, молча
  # пропустить его нельзя: вложенный код останется с ad-hoc подписью сборки.
  for component in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE"
  do
    if [[ ! -e "$component" ]]; then
      echo "Не нашёл вложенный компонент Sparkle: $component" >&2
      echo "Разложение фреймворка изменилось — обновите список, иначе часть кода" >&2
      echo "уедет в релиз с ad-hoc подписью." >&2
      exit 1
    fi
  done

  sign "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  # Единственный компонент, которому Sparkle отдельно велит сохранять
  # entitlements. У нас приложение не в песочнице, и сейчас там пустой список —
  # но это ровно то место, где право на сеть появится, если песочница когда-то
  # включится. Флаг стоит заранее, чтобы подпись не съела его молча.
  sign --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  sign "$SPARKLE_VERSION/Autoupdate"
  sign "$SPARKLE_VERSION/Updater.app"
  sign "$SPARKLE"

  # Приложение — последним. Идентификатор задаём явно, чтобы он не зависел от
  # имени продукта и настроек сборки.
  sign --identifier "$BUNDLE_ID" "$APP_PATH"

  # А вот при проверке --deep как раз нужен: он обходит вложенный код.
  echo "→ Проверяю подпись"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  # Ради чего проверка: пропущенный компонент останется с ad-hoc подписью
  # сборки. Нотаризация такое отклонит, а если и пропустит — сломается ровно
  # установка обновления. Сверяем удостоверение каждого компонента с
  # удостоверением приложения.
  APP_AUTHORITY=$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)
  echo "  удостоверение: ${APP_AUTHORITY:-ad-hoc}"
  for component in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE"
  do
    authority=$(codesign -dvv "$component" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    if [[ "$authority" != "$APP_AUTHORITY" ]]; then
      echo "Компонент подписан не тем же удостоверением: $component" >&2
      echo "  приложение: ${APP_AUTHORITY:-ad-hoc}" >&2
      echo "  компонент:  ${authority:-ad-hoc}" >&2
      exit 1
    fi
  done
  echo "  вложенный код подписан тем же удостоверением"
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
