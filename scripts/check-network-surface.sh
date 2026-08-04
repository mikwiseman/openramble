#!/bin/bash
# Проверяет главное обещание продукта: сеть используется только там, где
# это заявлено пользователю.
#
# Разрешено ровно два места:
#   • ModelDownloading.swift — загрузка модели по кнопке
#   • обёртка Sparkle        — проверка обновлений с согласия пользователя
#
# Всё остальное — нарушение. Список символов шире очевидного URLSession:
# скачать данные в Foundation можно доброй дюжиной способов, и каждый из них
# незаметно превратил бы «работает в самолёте» в неправду.

set -euo pipefail
cd "$(dirname "$0")/.."

# Файлы, которым сеть разрешена.
ALLOWED='Packages/LocalASR/Sources/LocalASR/ModelDownloading.swift|SparkleUpdater.swift'

# Проверяем только shipping-код. Тесты намеренно создают URLSession, читают
# локальные fixture-файлы через Data(contentsOf:) и поднимают control-connect;
# считать эти seams сетевой поверхностью продукта — ложный PASS/FAIL сигнал.
SHIPPING_PATHS=(Packages/DictationCore/Sources Packages/LocalASR/Sources apps/macos/WaiDictation)

# Символы, которые умеют ходить в сеть.
FORBIDDEN='URLSession|NWConnection|NWBrowser|CFNetwork|CFStream|WKWebView|NSNetService|NSURLConnection'
# Незаметные способы скачать: эти инициализаторы принимают URL и молча идут в сеть.
FORBIDDEN+='|Data\(contentsOf:|String\(contentsOf:|NSAttributedString\(url:|NSImage\(contentsOf:|AVAsset\(url:'
# Отправка речи на серверы Apple — прямо противоречит смыслу продукта.
FORBIDDEN+='|SFSpeechRecognizer'
# Синхронизация между устройствами: сюда данные тоже не должны попадать.
FORBIDDEN+='|NSUbiquitousKeyValueStore|CKContainer|CKDatabase'
# Загрузка моделей мимо нашего манифеста.
FORBIDDEN+='|MLModelCollection'

status=0

echo "Проверяю сетевые символы…"
while IFS= read -r hit; do
  file="${hit%%:*}"
  if [[ "$file" =~ $ALLOWED ]]; then
    continue
  fi
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "НАРУШЕНИЕ: сеть вне разрешённых мест."
    status=1
  fi
  echo "  $hit"
done < <(grep -rnE "$FORBIDDEN" "${SHIPPING_PATHS[@]}" 2>/dev/null \
  | grep -v '^Binary' \
  | grep -vE ':[0-9]+: *//' \
  | grep -vE 'URLSessionModelDownloader\(\)|: ModelDownloading' \
  || true)

# Буфер обмена — отдельная история. Голый clearContents() отдаёт продиктованный
# текст в Universal Clipboard, то есть на все устройства Apple ID через iCloud.
# Писать в буфер можно только через prepareForNewContents(with: .currentHostOnly).
#
# declareTypes(_:owner:) — то же самое другими словами. Это легаси-способ начать
# новую запись: он так же сбрасывает буфер и так же не ставит ограничения
# текущим компьютером. Проверка на одно clearContents() ловила бы только
# современное написание, а обещание пользователю сформулировано не про имя
# метода.
FORBIDDEN_PASTEBOARD='clearContents\(\)|declareTypes\('
echo "Проверяю запись в буфер обмена…"
while IFS= read -r hit; do
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "НАРУШЕНИЕ: сброс буфера мимо .currentHostOnly уносит диктовку"
    echo "в Universal Clipboard — на все устройства Apple ID."
    echo "Используйте prepareForNewContents(with: .currentHostOnly)."
    status=1
  fi
  echo "  $hit"
  # Комментарии исключаются так же, как в проверке сетевых символов. Без этого
  # гейт падал на строке, которая сама объясняет, почему так писать нельзя, —
  # а ложное срабатывание тут дороже пропуска: его начинают обходить, и
  # однажды обойдут настоящее.
done < <(grep -rnE "$FORBIDDEN_PASTEBOARD" "${SHIPPING_PATHS[@]}" 2>/dev/null \
  | grep -v '^Binary' \
  | grep -vE ':[0-9]+: *//' \
  || true)

# Обновления обязаны молчать, пока их не включили. Это не косметика:
# без SUEnableAutomaticChecks=false Sparkle на втором запуске сам спросит
# разрешение и по умолчанию включит проверки — приложение пойдёт в сеть без
# команды, и обещание на главной странице станет неправдой.
echo "Проверяю настройки обновлений…"
PROJECT_YML="apps/macos/project.yml"
declare -a REQUIRED_UPDATE_KEYS=(
  "SUEnableAutomaticChecks: false"
  "SUSendProfileInfo: false"
  "SUAllowsAutomaticUpdates: false"
)
for required in "${REQUIRED_UPDATE_KEYS[@]}"; do
  if grep -qF "$required" "$PROJECT_YML"; then
    continue
  fi
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "НАРУШЕНИЕ: обновления настроены не так, как обещано пользователю."
    status=1
  fi
  echo "  в $PROJECT_YML нет строки «$required»"
done

# Логирование самого текста диктовки — то, чего пользователь точно не ждёт.
echo "Проверяю логирование текста…"
while IFS= read -r hit; do
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "НАРУШЕНИЕ: в лог попадает распознанный текст."
    status=1
  fi
  echo "  $hit"
done < <(grep -rnE 'log(ger)?\.(info|debug|error|warning|notice)\(.*(transcript|dictatedText|recognizedText)' \
  "${SHIPPING_PATHS[@]}" 2>/dev/null || true)

if [[ $status -eq 0 ]]; then
  echo ""
  echo "Сетевая поверхность в порядке: загрузка модели и обновления (по умолчанию выключенные), больше ничего."
fi
exit $status
