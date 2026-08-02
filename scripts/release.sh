#!/bin/bash
# Выпустить релиз: образ, подпись обновления, запись в appcast.
#
# Обновления Sparkle проверяются подписью EdDSA — приложение поставит только
# тот образ, который подписан вашим ключом. Приватный ключ в репозиторий не
# попадает никогда: он лежит отдельным файлом, путь передаётся переменной
# SPARKLE_KEY_PATH.
#
# Один раз, чтобы завести ключ:
#   generate_keys                      создаёт пару и кладёт приватный ключ
#                                      в связку ключей, печатает публичный
#   generate_keys -x ~/.wai-dictation/sparkle-key
#                                      выгружает приватный ключ в файл
#   публичный ключ → SUPublicEDKey в apps/macos/project.yml (он публичный,
#                                      его место в репозитории)
#
# Запуск:
#   SPARKLE_KEY_PATH=~/.wai-dictation/sparkle-key \
#   DEVELOPER_ID="Developer ID Application: …" \
#   NOTARY_PROFILE="…" \
#   ./scripts/release.sh
#
# Пошагово — docs/release.md.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Wai Dictation"
APP_PATH="artifacts/build/WaiDictation.xcarchive/Products/Applications/$APP_NAME.app"
APPCAST="docs/appcast.xml"
NOTES_DIR="docs/release-notes"
# Где будут лежать образы. Релизы GitHub — обычная статика, своего сервера
# у продукта нет.
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/mikwiseman/wai-dictation/releases/download}"
# Сколько версий держать в ленте. Старые никому не нужны: Sparkle смотрит
# только на самую свежую.
KEEP_ITEMS=10

SPARKLE_KEY_PATH="${SPARKLE_KEY_PATH:-}"
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_BIN="${SPARKLE_BIN:-}"

fail() {
  echo "" >&2
  echo "$1" >&2
  exit 1
}

# --- Ключ подписи обновлений -------------------------------------------------

if [[ -z "$SPARKLE_KEY_PATH" ]]; then
  fail "Не задан SPARKLE_KEY_PATH — файл с приватным ключом Sparkle.

Если ключа ещё нет:
  generate_keys                                   создать пару
  generate_keys -x ~/.wai-dictation/sparkle-key   выгрузить приватный ключ в файл
  chmod 600 ~/.wai-dictation/sparkle-key

Публичный ключ, который напечатает generate_keys, впишите в
apps/macos/project.yml как SUPublicEDKey. Приватный не коммитьте никогда.

Сам generate_keys приезжает вместе с пакетом Sparkle:
  ~/Library/Developer/Xcode/DerivedData/WaiDictation-*/SourcePackages/artifacts/sparkle/Sparkle/bin/"
fi

if [[ ! -f "$SPARKLE_KEY_PATH" ]]; then
  fail "Файла с ключом нет: $SPARKLE_KEY_PATH
Проверьте путь или выгрузите ключ заново: generate_keys -x \"$SPARKLE_KEY_PATH\""
fi

# --- Инструменты Sparkle -----------------------------------------------------

# sign_update приезжает внутри пакета Sparkle. Xcode распаковывает его в
# DerivedData при первой сборке, поэтому отдельно ставить ничего не нужно.
find_sparkle_tool() {
  local tool="$1" pattern candidate
  if [[ -n "$SPARKLE_BIN" ]]; then
    [[ -x "$SPARKLE_BIN/$tool" ]] && { printf '%s' "$SPARKLE_BIN/$tool"; return 0; }
    return 1
  fi
  for pattern in "WaiDictation-*" "*"; do
    for candidate in "$HOME/Library/Developer/Xcode/DerivedData"/$pattern/SourcePackages/artifacts/sparkle/Sparkle/bin/"$tool"; do
      [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    done
  done
  return 1
}

SIGN_UPDATE=$(find_sparkle_tool sign_update) || fail "Не нашёл sign_update.

Он лежит внутри пакета Sparkle, который Xcode распаковывает при сборке:
  ~/Library/Developer/Xcode/DerivedData/WaiDictation-*/SourcePackages/artifacts/sparkle/Sparkle/bin/

Соберите приложение хотя бы раз, либо укажите путь вручную:
  SPARKLE_BIN=/путь/к/Sparkle/bin ./scripts/release.sh"

# --- Подпись и нотаризация самого приложения ---------------------------------

# Ненотаризованный образ Gatekeeper не пустит, и обновление превратится в
# сломанное приложение у всех, кто его поставил. Пробные сборки — отдельно,
# через scripts/build-dmg.sh.
if [[ -z "$DEVELOPER_ID" || -z "$NOTARY_PROFILE" ]]; then
  fail "Релиз собирается только подписанным и нотаризованным.

  DEVELOPER_ID=\"Developer ID Application: Имя (TEAMID)\"
  NOTARY_PROFILE=\"имя профиля из xcrun notarytool store-credentials\"

Пробный образ без подписи: ./scripts/build-dmg.sh"
fi

# --- Проверки перед сборкой --------------------------------------------------

# Версию берём из project.yml до сборки. Дальше её же проверим по собранному
# Info.plist, но описание изменений нужно потребовать раньше: сборка с
# нотаризацией идёт минуты, и упираться в отсутствующий текстовый файл после
# них — потерянное время на каждом релизе.
PROJECT_YML="apps/macos/project.yml"
yml_value() {
  sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$PROJECT_YML" | head -1
}

MARKETING_VERSION=$(yml_value MARKETING_VERSION)
SHORT_VERSION=$(yml_value CFBundleShortVersionString)

[[ -n "$MARKETING_VERSION" ]] || fail "В $PROJECT_YML не нашёлся MARKETING_VERSION"

# Две строки об одной версии обязаны совпадать: Sparkle показывает человеку
# CFBundleShortVersionString, а имя образа берётся из него же.
if [[ "$MARKETING_VERSION" != "$SHORT_VERSION" ]]; then
  fail "Версии в $PROJECT_YML разошлись:
  MARKETING_VERSION           = $MARKETING_VERSION
  CFBundleShortVersionString  = $SHORT_VERSION
Обе строки должны быть одинаковыми."
fi

NOTES_PATH="$NOTES_DIR/$MARKETING_VERSION.md"
if [[ ! -f "$NOTES_PATH" ]]; then
  mkdir -p "$NOTES_DIR"
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
  {
    if [[ -n "$LAST_TAG" ]]; then
      git log --no-merges --pretty=format:'- %s' "$LAST_TAG..HEAD"
    else
      git log --no-merges --pretty=format:'- %s'
    fi
  } | grep -vE '^- (chore|docs|test|refactor|wip|ci)[(:]' > "$NOTES_PATH" || true
  echo "" >> "$NOTES_PATH"

  fail "Нет описания изменений — я набросал черновик из коммитов:
  $NOTES_PATH

Перепишите его человеческим языком (это увидят все, кому предложат
обновление) и запустите скрипт заново. Останавливаюсь до сборки, чтобы
не гонять нотаризацию впустую."
fi

echo "→ Проверяю сетевую поверхность"
./scripts/check-network-surface.sh >/dev/null

echo "→ Гоняю тесты"
swift test --package-path Packages/DictationCore >/dev/null
swift test --package-path Packages/LocalASR >/dev/null

# --- Сборка образа -----------------------------------------------------------

echo "→ Собираю образ"
DEVELOPER_ID="$DEVELOPER_ID" NOTARY_PROFILE="$NOTARY_PROFILE" ./scripts/build-dmg.sh

[[ -d "$APP_PATH" ]] || fail "Сборка не дала приложения: $APP_PATH"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
}

VERSION=$(plist_value CFBundleShortVersionString)
BUILD=$(plist_value CFBundleVersion)
MIN_OS=$(plist_value LSMinimumSystemVersion)
FEED_URL=$(plist_value SUFeedURL)
PUBLIC_KEY=$(plist_value SUPublicEDKey)

[[ -n "$VERSION" && -n "$BUILD" ]] || fail "В Info.plist нет версии или номера сборки"
[[ -n "$FEED_URL" ]] || fail "В Info.plist нет SUFeedURL — приложение не будет знать, где искать обновления"

if [[ -z "$PUBLIC_KEY" ]]; then
  fail "В Info.plist нет SUPublicEDKey.

Без него обновление проверяется только подписью Apple, а это Sparkle считает
устаревшим и небезопасным. Возьмите публичный ключ:
  generate_keys -p
и впишите его в apps/macos/project.yml:
  SUPublicEDKey: \"<ключ>\""
fi

DMG_PATH="artifacts/dmg/WaiDictation-$VERSION.dmg"
[[ -f "$DMG_PATH" ]] || fail "Образа нет: $DMG_PATH"

echo "  версия $VERSION, сборка $BUILD, минимум macOS $MIN_OS"

# --- Что нового --------------------------------------------------------------

# Описание уже потребовали до сборки. Здесь только сверяем, что собралось ровно
# то, на что оно написано: расхождение значило бы, что xcodegen взял версию не
# из project.yml.
if [[ "$VERSION" != "$MARKETING_VERSION" ]]; then
  fail "Собранная версия $VERSION не совпадает с $MARKETING_VERSION из $PROJECT_YML.
Перегенерируйте проект: cd apps/macos && xcodegen generate"
fi

# --- Подпись обновления ------------------------------------------------------

echo "→ Подписываю образ ключом обновлений"
SIGNATURE=$("$SIGN_UPDATE" -p --ed-key-file "$SPARKLE_KEY_PATH" "$DMG_PATH")
[[ -n "$SIGNATURE" ]] || fail "sign_update не выдал подпись"

# Проверяем сразу же: подпись, которую никто не проверил, не подпись.
"$SIGN_UPDATE" --verify --ed-key-file "$SPARKLE_KEY_PATH" "$DMG_PATH" "$SIGNATURE" >/dev/null \
  || fail "Подпись не сходится с ключом $SPARKLE_KEY_PATH"

# А теперь то, чего предыдущая проверка не делает вовсе.
#
# Она сверяет подпись с тем же приватным ключом, которым только что подписала, —
# то есть не может не сойтись. Настоящий вопрос другой: соответствует ли
# ПУБЛИЧНЫЙ ключ, зашитый в приложение, этому приватному. Разошлись — релиз
# проходит зелёным, лента публикуется, а обновление не устанавливается ни у
# кого и никогда: приложение проверяет подпись своим ключом, а он чужой.
#
# Файл ключа Sparkle — это base64 от 32-байтового зерна ed25519, поэтому
# публичный выводится из него напрямую. Проверено перекрёстно: выведенный так
# ключ подтверждает подпись, сделанную самим sign_update.
echo "→ Сверяю публичный ключ в приложении с ключом подписи"
DERIVED_KEY=$(swift - "$SPARKLE_KEY_PATH" <<'SWIFT'
import CryptoKit
import Foundation

let path = CommandLine.arguments[1]
guard let text = try? String(contentsOfFile: path, encoding: .utf8),
      let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else {
    FileHandle.standardError.write(Data("ключ подписи не читается как зерно ed25519\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
) || fail "Не удалось вывести публичный ключ из $SPARKLE_KEY_PATH"

if [[ "$DERIVED_KEY" != "$PUBLIC_KEY" ]]; then
  fail "Публичный ключ в приложении не от того приватного, которым подписан образ.

В Info.plist:        $PUBLIC_KEY
Соответствует ключу: $DERIVED_KEY

Выпускать так нельзя: обновление не установится ни у кого. Впишите в
apps/macos/project.yml правильный ключ и пересоберите:
  SUPublicEDKey: \"$DERIVED_KEY\""
fi

LENGTH=$(stat -f%z "$DMG_PATH")
DMG_URL="$DOWNLOAD_BASE/v$VERSION/$(basename "$DMG_PATH")"

# --- Лента обновлений --------------------------------------------------------

echo "→ Обновляю $APPCAST"
APPCAST="$APPCAST" NOTES_PATH="$NOTES_PATH" KEEP_ITEMS="$KEEP_ITEMS" \
VERSION="$VERSION" BUILD="$BUILD" MIN_OS="$MIN_OS" FEED_URL="$FEED_URL" \
DMG_URL="$DMG_URL" LENGTH="$LENGTH" SIGNATURE="$SIGNATURE" APP_NAME="$APP_NAME" \
python3 scripts/update-appcast.py

# --- Что дальше --------------------------------------------------------------

cat <<TEXT

Готово. Осталось разложить по местам:

  1. Проверьте ленту:      git diff $APPCAST
  2. Создайте релиз и залейте образ:
       gh release create v$VERSION "$DMG_PATH" --title "$VERSION" --notes-file "$NOTES_PATH"
     Ссылка в ленте ждёт образ ровно здесь:
       $DMG_URL
  3. Закоммитьте ленту и описание — GitHub Pages раздаёт их из docs/:
       git add $APPCAST $NOTES_PATH && git commit -m "release: $VERSION"
       git push
  4. Через пару минут убедитесь, что лента живая:
       curl -sSf $FEED_URL | head -20

И только потом — «Проверить обновления…» в старой версии приложения.
TEXT
