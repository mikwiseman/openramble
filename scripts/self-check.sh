#!/bin/bash
# Самопроверка живого пути: то, что нельзя проверить без человека.
#
# Всё остальное здесь проверяется само — логика тестами, сетевая поверхность
# гейтом, качество распознавания замерами. Не проверено ровно то, ради чего
# продукт существует: живой голос в настоящий микрофон. Синтез `say`, на
# котором сделаны все цифры в docs/benchmarks.md, ровный и без дикции, и
# переносить его результаты на человека нельзя.
#
# Скрипт ведёт по шагам, меряет и печатает сводку, которую можно вставить в
# issue. Он ничего не чинит и ничего не устанавливает — только показывает.
#
# Чего он проверить не может в принципе — горячая клавиша, вставка в чужое
# приложение, режим без удержания, защищённый ввод: это docs/manual-check.md,
# десять минут руками.
#
# Запуск — только в терминале, руками:
#   ./scripts/self-check.sh
#   ./scripts/self-check.sh --keep-recordings   оставить записи для разбора
#
# Переменные окружения:
#   WAI_SELFCHECK_MAX_SECONDS   предел одной записи, по умолчанию 60
#
# Коды возврата: 0 всё прошло · 1 прошло с проблемами · 64 неверный аргумент ·
# 65 нет человека за клавиатурой · 69 нет модели или не то железо ·
# 70 сломан инструмент · 74 микрофон не отдал звук · 77 нет разрешения ·
# 130 прервано.

set -uo pipefail
cd "$(dirname "$0")/.."

WORK=".build/self-check"
PROBE="$WORK/mic-probe"
PROBE_SOURCE="scripts/self-check-mic.swift"
BENCH="$WORK/asr-bench"

# Предел одной записи. Не «страховка от зависания», а названное вслух
# ограничение: если он сработал, это видно в отчёте отдельной строкой.
MAX_RECORD_SECONDS="${WAI_SELFCHECK_MAX_SECONDS:-60}"
# Сколько ждать ответа на системное окно разрешения.
PERMISSION_TIMEOUT=120
# Короче этого запись бессмысленна — человек не успел ничего сказать.
MIN_RECORD_SECONDS=1.5
# Тише этого — тишина: не тот вход, выключенный микрофон, закрытая крышка.
MIN_PEAK=0.02

KEEP_RECORDINGS=0

RU_PHRASE="Завтра утром созвонимся и обсудим, что переносим на следующую неделю. Черновик я пришлю сегодня вечером, чтобы вы успели посмотреть."
MIX_PHRASE="Нужно сделать pull request и запустить deploy через Sentry. Если сломается, вернём всё назад и посмотрим логи на staging."

# ── Состояние отчёта ──────────────────────────────────────────────────────────
#
# Строками, а не массивами: /bin/bash на macOS — версии 3.2, и пустой массив
# под `set -u` там роняет скрипт. Падать в отчёте о проверке — последнее дело.

SUMMARY=""
SKIPPED=""
PROBLEMS=0
SUMMARY_PRINTED=0
STEP="запуск"
MODEL_REVISION=""
MODEL_LOAD=""
MIC_BUSY_BEFORE="неизвестно"
INPUT_DEVICE="неизвестно"
RUNNING_PID=""
RU_TOTAL=""
MIX_TOTAL=""
RU_WER=""
MIX_WER=""

# Выше этого фраза не «распозналась хуже», а не распозналась. Живой голос всегда
# хуже синтеза, и спорить о десяти процентах разницы бессмысленно — но когда
# половина слов не та, называть это работающей диктовкой нельзя. Порог для
# смешанной фразы выше: там и на синтезе 26,9%.
RU_WER_BROKEN=50
MIX_WER_BROKEN=70

add_line() { SUMMARY="${SUMMARY}${1}"$'\n'; }
# Каждый пропуск называется вслух и попадает в сводку. Непроверенное, о котором
# не сказали, читается как проверенное — это и есть главный способ соврать.
add_skip() { SKIPPED="${SKIPPED}  · ${1}"$'\n'; }
add_problem() { PROBLEMS=$((PROBLEMS + 1)); }

# ── Печать ────────────────────────────────────────────────────────────────────

step() {
  STEP="$1"
  printf '\n\033[1m── %s\033[0m\n' "$1"
}
say() { printf '%s\n' "$1"; }
good() { printf '  ✓ %s\n' "$1"; }
note() { printf '  · %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; }
hint() { printf '    %s\n' "$1"; }

# ── Завершение ────────────────────────────────────────────────────────────────

print_summary() {
  [[ $SUMMARY_PRINTED -eq 1 ]] && return 0
  SUMMARY_PRINTED=1
  printf '\n\033[1m── Сводка\033[0m\n'
  say "Скопируйте всё между чертами в issue:"
  say "────────────────────────────────────────────────────────────"
  say "Wai Dictation — самопроверка живого пути"
  say "дата:      $(date '+%Y-%m-%d %H:%M')"
  say "система:   macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n machdep.cpu.brand_string)"
  say "исходники: $(git rev-parse --short HEAD 2>/dev/null || echo 'не репозиторий')"
  [[ -n "$MODEL_REVISION" ]] && say "модель:    $MODEL_REVISION"
  say "вход:      $INPUT_DEVICE"
  say ""
  [[ -n "$SUMMARY" ]] && printf '%s' "$SUMMARY"
  if [[ -n "$SKIPPED" ]]; then
    say ""
    say "не проверено:"
    printf '%s' "$SKIPPED"
  fi
  say ""
  say "этот скрипт не проверяет вообще (см. docs/manual-check.md):"
  say "  · горячую клавишу, вставку в чужое приложение, режим без удержания,"
  say "    отмену по Escape, защищённый ввод, словарь замен"
  say ""
  say "итог: $1"
  say "────────────────────────────────────────────────────────────"
}

cleanup_recordings() {
  if [[ $KEEP_RECORDINGS -eq 1 ]]; then
    if [[ -f "$WORK/ru-live.wav" || -f "$WORK/mix-live.wav" ]]; then
      say ""
      say "Записи оставлены по вашей просьбе: $WORK/"
    fi
    return 0
  fi
  # По умолчанию голос не остаётся на диске — ровно как в самом приложении.
  rm -f "$WORK/ru-live.wav" "$WORK/mix-live.wav"
}

finish() {
  cleanup_recordings
  print_summary "$2"
  exit "$1"
}

on_exit() {
  local code=$?
  [[ $SUMMARY_PRINTED -eq 1 ]] && return 0
  cleanup_recordings
  print_summary "оборвалось неожиданно, код $code — это дефект самой проверки"
}

on_interrupt() {
  printf '\n'
  # Записывающий процесс запущен в фоне, а фоновые процессы SIGINT не получают:
  # без этой строки микрофон остался бы включённым ровно в том сценарии, где
  # проверка обязана быть чище всех.
  [[ -n "$RUNNING_PID" ]] && kill -KILL "$RUNNING_PID" 2>/dev/null
  bad "Прервано на шаге: $STEP"
  add_problem
  finish 130 "прервано человеком на шаге «$STEP»"
}

trap on_exit EXIT
trap on_interrupt INT TERM

# ── Опрос человека ────────────────────────────────────────────────────────────

ask_enter() {
  local answer
  printf '\n  %s ' "$1"
  read -r answer || { printf '\n'; finish 65 "стандартный ввод кончился на шаге «$STEP»"; }
}

# 0 — да, 1 — нет, 2 — не ответили.
ask_yes_no() {
  local answer attempt
  for attempt in 1 2 3 4 5; do
    printf '\n  %s [д/н] ' "$1"
    read -r answer || { printf '\n'; return 2; }
    case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
      д|да|y|yes) return 0 ;;
      н|нет|n|no) return 1 ;;
      *) printf '    Ответьте «д» или «н».\n' ;;
    esac
  done
  return 2
}

# ── Ограничение по времени ────────────────────────────────────────────────────

# Ни один вызов не имеет права висеть. Механизм один на все вызовы — чтобы его
# было видно в одном месте и чтобы он был проверяем: run_limited 1 … sleep 30.
#
# Источник ввода задаётся явно. Фоновой команде bash сам подставляет /dev/null,
# и запись «говорите до Enter» заканчивалась бы мгновенно, с виду успешно, а на
# деле с пустым файлом. Терминал нужен ровно одной команде — записи, — и она
# просит его сама, а не получает исподволь.
#
# Использование: run_limited <секунд> <файл вывода> <файл ввода> <команда…>;
# 124 — не дождались.
run_limited() {
  local limit="$1" out="$2" input="$3"
  shift 3
  "$@" >"$out" 2>&1 <"$input" &
  RUNNING_PID=$!
  local waited=0 ticks=$((limit * 10)) status
  while kill -0 "$RUNNING_PID" 2>/dev/null; do
    if [[ $waited -ge $ticks ]]; then
      # Оболочка сама печатает «Terminated: 15», когда замечает смерть фоновой
      # задачи. На экране человека это выглядит как поломка скрипта, а не как
      # сработавший предел, про который он сейчас прочитает своими словами.
      exec 3>&2 2>/dev/null
      kill -TERM "$RUNNING_PID" 2>/dev/null
      sleep 1
      kill -KILL "$RUNNING_PID" 2>/dev/null
      wait "$RUNNING_PID"
      exec 2>&3 3>&-
      RUNNING_PID=""
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$RUNNING_PID"
  status=$?
  RUNNING_PID=""
  return $status
}

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
elapsed() { perl -e 'printf "%.2f", $ARGV[1] - $ARGV[0]' "$1" "$2"; }
# Сравнение дробных чисел: bash умеет только целые. Пустая строка — не число, и
# ответ «меньше» на неё был бы выдумкой.
less_than() {
  [[ -z "$1" ]] && return 2
  perl -e 'exit(($ARGV[0] < $ARGV[1]) ? 0 : 1)' "$1" "$2"
}

value_of() {
  grep -m1 "^$1=" "$2" 2>/dev/null | sed "s/^$1=//"
}

# ── Аргументы ─────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-recordings) KEEP_RECORDINGS=1; shift ;;
    -h|--help)
      sed -n '/^# Самопроверка живого пути/,/^# 130 прервано\./p' "$0" | sed 's/^# \{0,1\}//'
      SUMMARY_PRINTED=1
      exit 0
      ;;
    *)
      echo "Неизвестный аргумент: $1 (см. --help)" >&2
      SUMMARY_PRINTED=1
      exit 64
      ;;
  esac
done

if ! [[ "$MAX_RECORD_SECONDS" =~ ^[0-9]+$ ]] || [[ "$MAX_RECORD_SECONDS" -lt 5 ]]; then
  echo "WAI_SELFCHECK_MAX_SECONDS должен быть целым числом секунд не меньше 5." >&2
  SUMMARY_PRINTED=1
  exit 64
fi

# ── Шаг 0. Есть ли кому проверять ─────────────────────────────────────────────

if [[ ! -t 0 || ! -t 1 ]]; then
  cat >&2 <<'TEXT'
Этой проверке нужен человек за клавиатурой.

Она просит сказать фразу вслух и посмотреть глазами на то, чего программе не
видно. Без живого терминала делать ей нечего — и объявлять, что «всё прошло»,
она не станет.

Запустите в Терминале:  ./scripts/self-check.sh
TEXT
  SUMMARY_PRINTED=1
  exit 65
fi

printf '\033[1mWai Dictation — самопроверка живого пути\033[0m\n'
say ""
say "Пара минут. Понадобится сказать вслух две фразы с экрана."
say "Записи после распознавания удаляются (--keep-recordings оставит их)."

step "Шаг 0. Железо и окружение"

if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]]; then
  bad "Это не Apple Silicon."
  hint "Распознавание считается на нейромодуле, на Intel его нет вовсе."
  hint "Приложение запустится, но распознавать будет нечем."
  add_line "железо: не Apple Silicon — проверка невозможна"
  add_problem
  finish 69 "не то железо"
fi
good "Apple Silicon: $(sysctl -n machdep.cpu.brand_string)"
good "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  bad "Не найден swiftc."
  hint "Нужны Command Line Tools: xcode-select --install"
  add_line "окружение: нет swiftc — собрать нечем"
  add_problem
  finish 69 "нет тулчейна Swift"
fi

mkdir -p "$WORK"
if [[ ! -x "$PROBE" || "$PROBE_SOURCE" -nt "$PROBE" ]]; then
  say "  Собираю помощник для микрофона…"
  if ! xcrun swiftc -O "$PROBE_SOURCE" -o "$PROBE" 2>"$WORK/probe-build.log"; then
    bad "Помощник не собрался:"
    sed 's/^/    /' "$WORK/probe-build.log"
    add_line "окружение: не собрался $PROBE_SOURCE"
    add_problem
    finish 70 "не собрался помощник для микрофона"
  fi
fi
good "Помощник для микрофона готов"

# ── Шаг 1. Разрешения ─────────────────────────────────────────────────────────

step "Шаг 1. Разрешения"

# Имя терминала известно не всегда, а фраза должна читаться в обоих случаях:
# «включите переключатель у терминала» и «…у терминала «Apple_Terminal»».
TERM_SUFFIX=""
[[ -n "${TERM_PROGRAM:-}" ]] && TERM_SUFFIX=" «$TERM_PROGRAM»"
PERMISSION_OUT="$WORK/permission.out"

run_limited 15 "$PERMISSION_OUT" /dev/null "$PROBE" permission
PERMISSION_CODE=$?
PERMISSION=$(value_of permission "$PERMISSION_OUT")

if [[ $PERMISSION_CODE -eq 5 ]]; then
  say "  Разрешение на микрофон ещё не спрашивали."
  hint "Сейчас появится системное окно. Оно про терминал$TERM_SUFFIX, а не про"
  hint "Wai Dictation: записывать голос будет этот скрипт, а не приложение."
  ask_enter "Enter — показать окно."
  run_limited "$PERMISSION_TIMEOUT" "$PERMISSION_OUT" /dev/null "$PROBE" request
  PERMISSION_CODE=$?
  PERMISSION=$(value_of permission "$PERMISSION_OUT")
  if [[ $PERMISSION_CODE -eq 124 ]]; then
    bad "Окно разрешения осталось без ответа (предел — $PERMISSION_TIMEOUT с)."
    hint "Ждать бесконечно проверка не будет и «прошло» не напишет."
    add_line "микрофон (для скрипта): ответа на запрос не было"
    add_problem
    finish 77 "не дождались ответа на запрос разрешения"
  fi
fi

case $PERMISSION_CODE in
  0)
    good "Микрофон разрешён — терминалу$TERM_SUFFIX"
    add_line "микрофон (для скрипта): разрешён"
    ;;
  3|4)
    bad "Микрофон запрещён: $PERMISSION."
    hint "Открываю Системные настройки → Конфиденциальность → Микрофон."
    hint "Включите переключатель у терминала$TERM_SUFFIX, перезапустите его"
    hint "и запустите проверку заново."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null
    add_line "микрофон (для скрипта): запрещён ($PERMISSION)"
    add_problem
    finish 77 "нет разрешения на микрофон"
    ;;
  *)
    bad "Статус разрешения прочитать не вышло, код $PERMISSION_CODE:"
    sed 's/^/    /' "$PERMISSION_OUT"
    add_line "микрофон (для скрипта): статус не прочитан"
    add_problem
    finish 77 "статус разрешения не прочитан"
    ;;
esac

# Разрешения самого приложения — другие, отдельные от разрешений терминала.
# Прочитать их программой нельзя: базу TCC система не отдаёт. Значит, смотрим
# глазами и записываем ответ как ответ человека, а не как измерение.
APP_PATH=""
for candidate in "/Applications/Wai Dictation.app" "$HOME/Applications/Wai Dictation.app"; do
  if [[ -d "$candidate" ]]; then APP_PATH="$candidate"; break; fi
done
if [[ -z "$APP_PATH" ]]; then
  APP_PATH=$(mdfind "kMDItemCFBundleIdentifier == 'is.waiwai.dictation'" 2>/dev/null | head -1)
fi

if [[ -z "$APP_PATH" ]]; then
  warn "Приложение не установлено — его разрешения проверять не на чем."
  hint "Так и должно быть, если вы собираете из исходников и ещё не ставили .app."
  add_skip "разрешения приложения (микрофон, универсальный доступ) — приложение не найдено"
else
  good "Приложение найдено: $APP_PATH"
  say ""
  say "  Свои разрешения приложение получает отдельно от терминала, и прочитать"
  say "  их программой нельзя — система не отдаёт эту базу. Посмотрим глазами."
  if ask_yes_no "Открыть панели настроек и проверить? (н — пропустить)"; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null
    if ask_yes_no "Микрофон: «Wai Dictation» в списке и переключатель включён?"; then
      add_line "микрофон (приложения): включён — глазами"
    else
      add_line "микрофон (приложения): ВЫКЛЮЧЕН — глазами"
      add_problem
      warn "Без него диктовка не запишет ни звука."
    fi
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null
    if ask_yes_no "Универсальный доступ: «Wai Dictation» включён?"; then
      add_line "универсальный доступ: включён — глазами"
    else
      add_line "универсальный доступ: ВЫКЛЮЧЕН — глазами"
      add_problem
      warn "Без него не сработает горячая клавиша и не вставится текст."
    fi
  else
    add_skip "разрешения приложения (микрофон, универсальный доступ) — пропущено по вашему выбору"
  fi
fi

# ── Шаг 2. Модель ─────────────────────────────────────────────────────────────

step "Шаг 2. Модель"

say "  Собираю asr-bench…"
if ! swift build -c release --package-path Packages/LocalASR --product asr-bench \
     >"$WORK/bench-build.log" 2>&1; then
  bad "asr-bench не собрался:"
  tail -20 "$WORK/bench-build.log" | sed 's/^/    /'
  add_line "модель: инструмент распознавания не собрался"
  add_problem
  finish 70 "не собрался asr-bench"
fi
cp "Packages/LocalASR/.build/release/asr-bench" "$BENCH"

STATUS_OUT="$WORK/status.out"
run_limited 60 "$STATUS_OUT" /dev/null "$BENCH" status
if [[ $? -ne 0 ]]; then
  bad "Модель не установлена — вот что сообщает инструмент:"
  sed 's/^/    /' "$STATUS_OUT"
  hint "Поставьте её в приложении: Настройки → Модель → Скачать."
  hint "Или из терминала: $BENCH install — 483 МБ, единственная сетевая операция."
  add_line "модель: не установлена — распознавать нечем"
  add_problem
  finish 69 "нет модели"
fi
MODEL_REVISION=$(grep -m1 '^Ревизия:' "$STATUS_OUT" | sed 's/^Ревизия: //')
good "Модель на месте, ревизия $MODEL_REVISION"

# Секунда тишины: она поднимает модель и ничего не рассказывает о голосе.
# Заодно это прогрев — иначе первая живая фраза заплатила бы за компиляцию под
# нейромодуль, и замер задержки оказался бы неправдой.
SILENCE="$WORK/silence.wav"
perl -e '
  my $samples = 16000;
  my $data = "\0" x ($samples * 2);
  my $size = length($data);
  print "RIFF", pack("V", 36 + $size), "WAVEfmt ", pack("V", 16), pack("v", 1),
        pack("v", 1), pack("V", 16000), pack("V", 32000), pack("v", 2),
        pack("v", 16), "data", pack("V", $size), $data;
' > "$SILENCE"

LOAD_OUT="$WORK/load.out"
run_limited 180 "$LOAD_OUT" /dev/null "$BENCH" transcribe "$SILENCE"
LOAD_CODE=$?
if [[ $LOAD_CODE -ne 0 ]]; then
  bad "Модель установлена, но не загрузилась (код $LOAD_CODE):"
  sed 's/^/    /' "$LOAD_OUT"
  add_line "модель: установлена, но не загружается"
  add_problem
  finish 70 "модель не загружается"
fi
MODEL_LOAD=$(grep -m1 'Модель загружена за' "$LOAD_OUT" | sed 's/[^0-9.]*\([0-9.]*\).*/\1/')
if [[ -z "$MODEL_LOAD" ]]; then
  bad "Модель отработала, но времени загрузки в выводе нет — сломан разбор:"
  sed 's/^/    /' "$LOAD_OUT"
  add_line "модель: время загрузки не прочитано"
  add_problem
  finish 70 "не прочитано время загрузки модели"
fi
good "Модель загрузилась за $MODEL_LOAD с"
if ! less_than "$MODEL_LOAD" 2; then
  hint "Долго — так бывает ровно один раз после установки: модель компилируется"
  hint "под нейромодуль. Второй запуск обязан быть быстрым."
fi
add_line "модель: готова, загрузка $MODEL_LOAD с"

# Состояние микрофона ДО записи. Без него «точка не погасла» ничего не значит:
# её мог зажечь Zoom, а не мы.
DEVICE_OUT="$WORK/device.out"
run_limited 15 "$DEVICE_OUT" /dev/null "$PROBE" device
if [[ $? -eq 0 ]]; then
  INPUT_DEVICE=$(value_of device "$DEVICE_OUT")
  MIC_BUSY_BEFORE=$(value_of running "$DEVICE_OUT")
  good "Вход: $INPUT_DEVICE"
  if [[ "$MIC_BUSY_BEFORE" == "yes" ]]; then
    warn "Микрофон уже слушает кто-то ещё."
    hint "Закройте Zoom, Диктофон, звонок в браузере — иначе проверка «индикатор"
    hint "погас» ничего не покажет: точка будет гореть не из-за нас."
  fi
else
  warn "Устройство ввода не опрошено — проверка индикатора будет неполной."
  add_skip "состояние устройства ввода до записи — опрос не прошёл"
fi

# ── Живая фраза ───────────────────────────────────────────────────────────────

PHRASE_OK=0
PHRASE_BROKEN=0
PHRASE_WER=""
PHRASE_CER=""
PHRASE_AUDIO=""
PHRASE_ASR=""
PHRASE_TOTAL=""
PHRASE_STARTUP=""

# live_phrase <имя файла> <метка> <порог отказа, %> <хуже чего, % или пусто> <эталон>
#
# Приговор фразе выносится здесь же, рядом с цифрами, а не у вызывающего: иначе
# человека сначала спрашивают «записать заново?», а уже потом сообщают, что
# записанное никуда не годится.
live_phrase() {
  local slug="$1" tag="$2" broken_at="$3" worse_than="$4" reference="$5"
  local wav="$WORK/$slug.wav"
  local probe_out="$WORK/$slug.probe"
  local manifest="$WORK/$slug.json"
  local eval_out="$WORK/$slug.eval"
  local attempt code stopped_at finished_at duration peak startup reason wall

  PHRASE_OK=0; PHRASE_BROKEN=0
  PHRASE_WER=""; PHRASE_CER=""; PHRASE_AUDIO=""; PHRASE_ASR=""
  PHRASE_TOTAL=""; PHRASE_STARTUP=""

  for attempt in 1 2 3; do
    say ""
    say "  Скажите это — обычным голосом, как обычно диктуете:"
    printf '\n\033[1m    %s\033[0m\n' "$reference"
    ask_enter "Enter — включаю микрофон. Enter ещё раз остановит запись."

    run_limited $((MAX_RECORD_SECONDS + 15)) "$probe_out" /dev/tty \
      "$PROBE" record "$wav" "$MAX_RECORD_SECONDS"
    code=$?
    stopped_at=$(now)

    case $code in
      0) ;;
      6)
        bad "Микрофона нет: система не отдала устройство ввода."
        sed 's/^/    /' "$probe_out"
        add_problem
        return 74
        ;;
      124)
        bad "Запись не остановилась сама — проверка её прекратила."
        add_problem
        return 74
        ;;
      *)
        bad "Записать не вышло, код $code:"
        sed 's/^/    /' "$probe_out"
        add_problem
        return 74
        ;;
    esac

    duration=$(value_of duration "$probe_out")
    peak=$(value_of peak "$probe_out")
    startup=$(value_of startup "$probe_out")
    reason=$(value_of stop_reason "$probe_out")
    wall=$(value_of wall "$probe_out")
    PHRASE_STARTUP="$startup"

    if [[ -z "$duration" || -z "$peak" || -z "$wall" ]]; then
      bad "Запись прошла, но чисел о ней нет — сломан разбор вывода:"
      sed 's/^/    /' "$probe_out"
      add_problem
      return 70
    fi
    if [[ "$reason" == "eof" ]]; then
      bad "Ввод кончился раньше, чем вы нажали Enter — записи не получилось."
      add_problem
      return 74
    fi
    if [[ "$reason" == "limit" ]]; then
      warn "Сработал предел в $MAX_RECORD_SECONDS с — конец фразы обрезан."
      hint "Поднять: WAI_SELFCHECK_MAX_SECONDS=120 ./scripts/self-check.sh"
    fi

    # Нейтрально, а не галочкой: годная эта запись или нет, решают проверки ниже.
    note "Записано $duration с, пик громкости $peak, микрофон включился за $startup с"

    if less_than "$duration" "$MIN_RECORD_SECONDS"; then
      warn "Записано $duration с — это не фраза, распознавать нечего."
      # Одна и та же короткая запись означает разное. Микрофон, который был
      # включён и молчал, и человек, нажавший Enter слишком рано, — разные
      # беды, и посылать чинить надо в разные стороны.
      if less_than "$MIN_RECORD_SECONDS" "$wall"; then
        hint "Микрофон был включён $wall с и звука почти не отдал — дело во входе,"
        hint "а не в вас: Системные настройки → Звук → Вход."
      else
        hint "Микрофон был включён всего $wall с — Enter нажался раньше, чем вы"
        hint "успели сказать фразу."
      fi
      if [[ $attempt -lt 3 ]]; then
        hint "Пробуем ещё раз — попытка $((attempt + 1)) из 3."
        continue
      fi
      add_problem
      return 74
    fi

    if less_than "$peak" "$MIN_PEAK"; then
      warn "Запись почти пустая: пик $peak. Голос до микрофона не дошёл."
      hint "Смотрите Системные настройки → Звук → Вход: тот ли вход и есть ли"
      hint "на нём уровень. Модель тут ни при чём — ей нечего распознавать."
      if [[ $attempt -lt 3 ]]; then
        hint "Пробуем ещё раз — попытка $((attempt + 1)) из 3."
        continue
      fi
      add_problem
      return 74
    fi

    # Сравниваем тем же скорером, что и docs/benchmarks.md: та же нормализация,
    # те же метрики. Иначе цифру не с чем было бы сопоставить.
    printf '[{"file": "%s", "reference": "%s", "tags": ["%s"]}]\n' \
      "$PWD/$wav" "$reference" "$tag" > "$manifest"

    say ""
    say "  Распознаю…"
    run_limited 300 "$eval_out" /dev/null "$BENCH" eval "$manifest"
    code=$?
    finished_at=$(now)
    if [[ $code -ne 0 ]]; then
      bad "Распознавание не прошло, код $code:"
      sed 's/^/    /' "$eval_out"
      add_problem
      return 70
    fi

    say ""
    # Только блок про эту запись. Диапазон по sed сюда не годится: следующая
    # строка на «===» — это сводка по группам, и она уезжала бы в вывод целиком.
    awk '/^=== /{block++} block==1 && !/^$/' "$eval_out" | sed 's/^/    /'

    PHRASE_WER=$(grep -m1 '^WER ' "$eval_out" | sed 's/^WER \([0-9.]*\)%.*/\1/')
    PHRASE_CER=$(grep -m1 '^WER ' "$eval_out" | sed 's/.*CER \([0-9.]*\)%.*/\1/')
    PHRASE_AUDIO=$(grep -m1 '^аудио ' "$eval_out" | sed 's/^аудио \([0-9.]*\) с.*/\1/')
    PHRASE_ASR=$(grep -m1 '^аудио ' "$eval_out" | sed 's/.*распознавание \([0-9.]*\) с.*/\1/')
    PHRASE_TOTAL=$(elapsed "$stopped_at" "$finished_at")
    if [[ -z "$PHRASE_WER" ]]; then
      bad "Распознавание прошло, но метрик в выводе нет — сломан разбор:"
      sed 's/^/    /' "$eval_out"
      add_problem
      return 70
    fi
    PHRASE_OK=1

    if ! less_than "$PHRASE_WER" "$broken_at"; then
      bad "Мимо ${PHRASE_WER}% слов при пороге ${broken_at}% — это отказ, а не"
      hint "«похуже, чем на синтезе». Смотрите строку «получено»: обрывок или"
      hint "чужой язык — дело во входе или в дикции, а не в модели."
      PHRASE_BROKEN=1
    elif [[ -n "$worse_than" ]] && ! less_than "$PHRASE_WER" "$worse_than"; then
      note "Хуже чистого русского (${worse_than}%) — ровно то, что показал синтез."
      hint "Если в расхождениях термины записаны кириллицей, это чинит словарь"
      hint "замен: Настройки → Словарь."
    fi

    say ""
    if ask_yes_no "Записать эту фразу заново? (н — дальше)"; then
      if [[ $attempt -lt 3 ]]; then continue; fi
      warn "Три попытки — предел, идём дальше."
    fi
    return 0
  done
  add_problem
  return 74
}

# ── Шаг 3. Живая русская речь ─────────────────────────────────────────────────

step "Шаг 3. Живая русская речь"
say "  Опорная цифра: на синтезе здесь WER 2,0% (docs/benchmarks.md)."

live_phrase "ru-live" "живая-русская" "$RU_WER_BROKEN" "" "$RU_PHRASE"
RU_CODE=$?
if [[ $RU_CODE -eq 0 && $PHRASE_OK -eq 1 ]]; then
  RU_TOTAL="$PHRASE_TOTAL"
  RU_WER="$PHRASE_WER"
  add_line "русская речь:    WER ${PHRASE_WER}%  CER ${PHRASE_CER}%   (на синтезе 2,0% / 0,8%)"
  add_line "                 аудио ${PHRASE_AUDIO} с, распознавание ${PHRASE_ASR} с, микрофон стартовал за ${PHRASE_STARTUP} с"
  [[ $PHRASE_BROKEN -eq 1 ]] && add_problem
else
  add_line "русская речь:    ПРОВАЛ — записать или распознать не вышло"
  [[ $RU_CODE -eq 0 ]] && RU_CODE=70
  finish "$RU_CODE" "живая русская фраза не прошла"
fi

# ── Шаг 4. Смешанная RU/EN ────────────────────────────────────────────────────

step "Шаг 4. Русская речь с английскими терминами"
say "  Главный сценарий продукта и его самое слабое место: на синтезе тут"
say "  WER 26,9% против 2,0% на чистом русском. Ошибка не в акустике — модель"
say "  пишет английский термин кириллицей."

live_phrase "mix-live" "живая-смешанная" "$MIX_WER_BROKEN" "$RU_WER" "$MIX_PHRASE"
MIX_CODE=$?
if [[ $MIX_CODE -eq 0 && $PHRASE_OK -eq 1 ]]; then
  MIX_TOTAL="$PHRASE_TOTAL"
  MIX_WER="$PHRASE_WER"
  add_line "смешанная RU/EN: WER ${PHRASE_WER}%  CER ${PHRASE_CER}%   (на синтезе 26,9% / 16,6%)"
  add_line "                 аудио ${PHRASE_AUDIO} с, распознавание ${PHRASE_ASR} с"
  [[ $PHRASE_BROKEN -eq 1 ]] && add_problem
else
  add_line "смешанная RU/EN: ПРОВАЛ — записать или распознать не вышло"
  [[ $MIX_CODE -eq 0 ]] && MIX_CODE=70
  finish "$MIX_CODE" "живая смешанная фраза не прошла"
fi

# ── Шаг 5. Задержка ───────────────────────────────────────────────────────────

step "Шаг 5. Задержка от конца речи до готового текста"
say "  Меряется от вашего Enter — это и есть отпущенная клавиша — до момента,"
say "  когда текст напечатан."
good "русская фраза:   $RU_TOTAL с"
good "смешанная фраза: $MIX_TOTAL с"
say ""
say "  Внутри этой цифры: остановка записи, закрытие файла, запуск отдельного"
say "  процесса, загрузка модели ($MODEL_LOAD с) и само распознавание."
say "  В приложении модель уже поднята, и процесс не стартует — там от клавиши"
say "  до текста остаётся распознавание и вставка. Значит, это верхняя оценка,"
say "  а не то, что вы почувствуете."
add_line "задержка «Enter → текст»: $RU_TOTAL с и $MIX_TOTAL с (с запуском процесса и загрузкой модели $MODEL_LOAD с)"
add_skip "задержка в самом приложении (клавиша → текст на экране) — только руками, docs/manual-check.md"

# ── Шаг 6. Микрофон отпущен ───────────────────────────────────────────────────

step "Шаг 6. Микрофон отпущен"

RELEASE_WAITED=""
RELEASE_FAILED=0
for tick in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  run_limited 15 "$DEVICE_OUT" /dev/null "$PROBE" device
  if [[ $? -ne 0 ]]; then
    RELEASE_FAILED=1
    break
  fi
  if [[ "$(value_of running "$DEVICE_OUT")" == "no" ]]; then
    RELEASE_WAITED=$(perl -e 'printf "%.2f", $ARGV[0] * 0.25' "$((tick - 1))")
    break
  fi
  sleep 0.25
done

if [[ $RELEASE_FAILED -eq 1 ]]; then
  warn "Состояние устройства прочитать не вышло."
  add_line "микрофон отпущен: не прочитано"
  add_skip "«индикатор погас» — состояние устройства недоступно"
elif [[ -z "$RELEASE_WAITED" ]]; then
  if [[ "$MIC_BUSY_BEFORE" == "yes" ]]; then
    warn "Устройство всё ещё слушают — но его слушали и до нашей записи."
    hint "Кто именно, отсюда не видно. Пройденной проверка не считается."
    add_line "микрофон отпущен: НЕ ОПРЕДЕЛЕНО — вход был занят ещё до записи"
    add_skip "«индикатор погас» — устройство держал кто-то ещё, наш вклад неразличим"
  else
    bad "Устройство ввода работает и через 5 секунд после записи."
    add_line "микрофон отпущен: НЕТ — устройство работает и через 5 с"
    add_problem
  fi
else
  good "Устройство ввода освободилось за $RELEASE_WAITED с"
  add_line "микрофон отпущен: да, за $RELEASE_WAITED с"
fi

say ""
say "  Это состояние устройства, а не сама оранжевая точка: показать её"
say "  программе система не даёт. Посмотрите глазами."
ask_yes_no "Оранжевая точка у строки меню погасла?"
case $? in
  0) add_line "оранжевая точка: погасла — глазами" ;;
  1)
    add_line "оранжевая точка: ГОРИТ — глазами"
    add_problem
    warn "Что-то продолжает слушать микрофон."
    ;;
  *) add_skip "оранжевая точка — ответа не было" ;;
esac

# ── Итог ──────────────────────────────────────────────────────────────────────

step "Готово"
# Цифры выносятся в сам итог. «Прошло» без чисел — это то, что читают вместо
# отчёта, и именно так плохое качество однажды поедет дальше как хорошее.
VERDICT="русская WER ${RU_WER}%, смешанная WER ${MIX_WER}%"
if [[ $PROBLEMS -eq 0 ]]; then
  good "Живой путь прошёл целиком: $VERDICT"
  say ""
  say "  Осталось десять минут руками: docs/manual-check.md — горячая клавиша,"
  say "  вставка в чужое приложение, режим без удержания, защищённый ввод."
  finish 0 "живая диктовка работает — $VERDICT"
else
  bad "Проблем: $PROBLEMS. Смотрите сводку."
  finish 1 "проблем $PROBLEMS — $VERDICT"
fi
