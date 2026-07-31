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
done < <(grep -rnE "$FORBIDDEN" Packages/*/Sources apps 2>/dev/null \
  | grep -v '^Binary' \
  | grep -vE ':[0-9]+: *//' \
  | grep -vE 'URLSessionModelDownloader\(\)|: ModelDownloading' \
  || true)

# Буфер обмена — отдельная история. Голый clearContents() отдаёт продиктованный
# текст в Universal Clipboard, то есть на все устройства Apple ID через iCloud.
# Писать в буфер можно только через prepareForNewContents(with: .currentHostOnly).
echo "Проверяю запись в буфер обмена…"
while IFS= read -r hit; do
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "НАРУШЕНИЕ: голый clearContents() уносит диктовку в Universal Clipboard."
    echo "Используйте prepareForNewContents(with: .currentHostOnly)."
    status=1
  fi
  echo "  $hit"
done < <(grep -rn 'clearContents()' Packages/*/Sources apps 2>/dev/null || true)

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
  Packages/*/Sources apps 2>/dev/null || true)

if [[ $status -eq 0 ]]; then
  echo ""
  echo "Сетевая поверхность в порядке: загрузка модели и обновления, больше ничего."
fi
exit $status
