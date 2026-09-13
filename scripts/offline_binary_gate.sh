#!/usr/bin/env bash
# Гейт «приложение не ходит в сеть» — на артефакте, а не на намерении.
#
# Зачем отдельно от negative_check.sh: тот грепает ИСХОДНИКИ. Сеть приезжает
# транзитом из зависимости: FluidAudio несёт в себе загрузчик моделей, и никакой
# grep по нашим .swift этого не увидит.
#
# ГРАНИЦЫ ПРОВЕРКИ, пересмотрены 13.09.2026:
#   1. Явные загрузки моделей речи и голосов используют URLSession:
#      SpeechModelInstaller.swift и SpeakerModelInstaller.swift. Они не
#      отправляют запись и не меняют DownloadUtils.enforceOffline у ASR.
#   2. Промпт, внешняя очистка и заполнение протокола могут отдельно передать
#      текст выбранному CLI-агенту после согласия. Его дочерние процессы и
#      сетевые соединения ЭТОТ гейт не проверяет.
#   3. Символы показывают доступные API, не факт их вызова. Базовый набор
#      включает URLSession из приложения и FluidAudio, настройки прокси.
#   4. Приложение НЕ в песочнице — ему нужен Универсальный доступ и перехват
#      событий, а App Sandbox это запрещает. Значит сеть не запрещена системой,
#      она ограничена дисциплиной кода. Это надо говорить вслух, а не
#      прятать за словом «офлайн».
#
# Поэтому гейт делает две вещи:
#   A. Пинует базовый набор сетевых символов. Набор ВЫРОС — значит появился
#      новый путь в сеть, и это надо смотреть глазами.
#   B. Если приложение запущено — спрашивает ядро, есть ли у него сокеты.
#      Это мгновенная эмпирическая проверка, не мониторинг. Гонять её во время
#      установки модели бессмысленно: там сокеты и должны быть. Проверка
#      отвечает на вопрос «молчит ли приложение в обычной работе».
#
# Коды: 0 — чисто, 1 — набор изменился или найден живой сокет, 2 — проверить нечем.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

BASELINE_COUNT=19
# 13.09.2026, release 0.2.2: независимый nm diff с 0.2.1 нашёл ровно два
# добавления URLRequest bridgeToObjectiveC/unconditionallyBridgeFromObjectiveC.
# Оба есть в SpeakerModelInstaller.swift.o: downloadTask и redirect delegate.
# Прежние 17 импортов сохранены, новых raw sockets/nw_* нет. Это явная загрузка
# моделей голосов; byte progress, limit и cancel проверены реальной загрузкой.
BASELINE_SHA="b6f834c2fb02afcb0dbac13c50a73f088468b6982a95b9ac24a0df8c7a59d6bc"
PATTERNS='NSURLSession|NSURLConnection|NSURLRequest|CFURLRequest|CFReadStream|CFSocket|CFNetwork|nw_connection|nw_endpoint|nw_path|SCNetworkReachability|CFHTTP|CFStreamCreatePairWithSocket'

status=0

# ── A. Символы в бинарнике ──────────────────────────────────────────────────
BIN="${1:-}"
if [ -z "$BIN" ]; then
  for candidate in ".build/release/IrizApp" ".build/debug/IrizApp"; do
    if [ -f "$candidate" ]; then BIN="$candidate"; break; fi
  done
fi

if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
  echo "offline_binary_gate: бинарник не найден — соберите (swift build -c release)" >&2
  exit 2
fi
if ! command -v nm >/dev/null 2>&1; then
  echo "offline_binary_gate: нет nm — проверить нечем, считаем отказом" >&2
  exit 2
fi

SYMS="$(nm -u "$BIN" 2>/dev/null | grep -E "$PATTERNS" | sort || true)"
COUNT="$(printf '%s' "$SYMS" | grep -c . || true)"
SHA="$(printf '%s\n' "$SYMS" | shasum -a 256 | cut -d' ' -f1)"

if [ "$COUNT" -gt "$BASELINE_COUNT" ]; then
  echo "offline_binary_gate: ОТКАЗ — сетевых символов стало больше: $COUNT (было $BASELINE_COUNT)" >&2
  echo "Появился новый путь в сеть. Смотреть глазами, а не поднимать порог:" >&2
  printf '%s\n' "$SYMS" | sed 's/^/  /' >&2
  status=1
elif [ "$SHA" != "$BASELINE_SHA" ]; then
  echo "offline_binary_gate: ВНИМАНИЕ — набор сетевых символов изменился при том же размере ($COUNT)." >&2
  echo "  было sha256 $BASELINE_SHA" >&2
  echo "  стало sha256 $SHA" >&2
  echo "Одни символы ушли, другие пришли — это не эквивалентная замена, проверить." >&2
  status=1
else
  echo "offline_binary_gate: символы — проверенный базовый набор без изменений ($COUNT)"
fi

# ── B. Живые сокеты ─────────────────────────────────────────────────────────
PID="$(pgrep -f '/Applications/iriz.app' 2>/dev/null | head -1 || true)"
if [ -z "$PID" ]; then
  echo "offline_binary_gate: приложение не запущено — эмпирическая проверка сокетов пропущена"
else
  # -a обязателен: без него -p и -i складываются по ИЛИ и печатают весь хост.
  SOCKETS="$(lsof -nP -a -p "$PID" -i 2>/dev/null || true)"
  if [ -n "$SOCKETS" ]; then
    echo "offline_binary_gate: ОТКАЗ — у запущенного приложения есть сетевые соединения:" >&2
    printf '%s\n' "$SOCKETS" | sed 's/^/  /' >&2
    status=1
  else
    UP="$(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')"
    echo "offline_binary_gate: в момент проверки сокетов нет (pid $PID, uptime $UP); история соединений не проверена"
  fi
fi

exit "$status"
