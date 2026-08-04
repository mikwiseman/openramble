#!/bin/bash
# Доказательство главного обещания: распознавание работает без сети.
#
# Проверка грепом по исходникам показывает только то, что мы сами не вызываем
# сетевые функции. Она ничего не говорит про то, что делают зависимости внутри.
# Здесь распознавание запускается в песочнице с полностью запрещённой сетью:
# если что-то попытается выйти наружу, оно упадёт.
#
# Запуск:
#   ./scripts/test-zero-network.sh [файл.wav]

set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE="${1:-}"
EXPECTED="${WAI_EXPECTED_TEXT:-Проверка работы без интернета}"
BENCH=".build-zero-network/asr-bench"

echo "→ Собираю инструмент"
swift build -c release --package-path Packages/LocalASR --product asr-bench 2>&1 | tail -1
mkdir -p .build-zero-network
cp "Packages/LocalASR/.build/release/asr-bench" "$BENCH"

# Модель должна быть уже установлена: её загрузка — единственная разрешённая
# сетевая операция, и проверяем мы то, что происходит после неё.
if ! "$BENCH" status >/dev/null 2>&1; then
  echo "Модель не установлена. Сначала: Packages/LocalASR/.build/release/asr-bench install" >&2
  exit 69
fi

# Если запись не передали, делаем короткую сами.
if [[ -z "$FIXTURE" ]]; then
  FIXTURE=".build-zero-network/probe.wav"
  if [[ ! -f "$FIXTURE" ]]; then
    echo "→ Готовлю пробную запись"
    say -v Milena -o ".build-zero-network/probe.aiff" "Проверка работы без интернета."
    afconvert -f WAVE -d LEI16@16000 -c 1 ".build-zero-network/probe.aiff" "$FIXTURE"
  fi
fi

if [[ -n "${1:-}" && -z "${WAI_EXPECTED_TEXT:-}" ]]; then
  echo "Для собственного WAV задайте WAI_EXPECTED_TEXT — проверка не принимает просто непустой вывод." >&2
  exit 64
fi

echo "→ Запускаю распознавание в песочнице без сети"

PROFILE=".build-zero-network/no-network.sb"
cat > "$PROFILE" <<'PROFILE_END'
(version 1)
(allow default)
;; Ровно то, ради чего всё это: любая попытка выйти в сеть запрещена.
(deny network*)
PROFILE_END

# Positive control: gate не считается работающим, пока unified log не
# приписал реальный network deny конкретному процессу curl.
CONTROL_LOG=".build-zero-network/sandbox-control.log"
: > "$CONTROL_LOG"
/usr/bin/log stream --style compact --level debug \
  --predicate 'subsystem == "com.apple.sandbox.reporting" OR senderImagePath CONTAINS[c] "sandbox"' \
  > "$CONTROL_LOG" 2>&1 &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT
sleep 1
sandbox-exec -f "$PROFILE" /usr/bin/curl --silent --show-error --connect-timeout 1 \
  https://example.com >/dev/null 2>&1 || true
sleep 1
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true
trap - EXIT
if ! grep -Eq 'Sandbox: curl\([0-9]+\) deny\([0-9]+\) network-' "$CONTROL_LOG"; then
  echo "ПРОВАЛ: sandbox positive control не появился в process-attributed deny log." >&2
  exit 1
fi

set +e
OUTPUT=$(sandbox-exec -f "$PROFILE" "$BENCH" transcribe "$FIXTURE" 2>&1)
STATUS=$?
set -e

echo "$OUTPUT" | sed 's/^/  /'

if [[ $STATUS -ne 0 ]]; then
  echo ""
  echo "ПРОВАЛ: без сети распознавание не работает (код $STATUS)."
  echo "Значит что-то в цепочке всё-таки ходит в интернет."
  exit 1
fi

# Заголовок `===` ничего не доказывает. Требуем ожидаемую фразу.
if ! echo "$OUTPUT" | grep -Fqi "$EXPECTED"; then
  echo ""
  echo "ПРОВАЛ: в результате нет ожидаемой фразы: $EXPECTED"
  exit 1
fi

echo ""
echo "Пройдено: речь распознана при полностью запрещённой сети."
