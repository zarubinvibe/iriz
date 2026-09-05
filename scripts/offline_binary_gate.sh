#!/usr/bin/env bash
# Гейт «приложение не ходит в сеть» — на артефакте, а не на намерении.
#
# Зачем отдельно от negative_check.sh: тот грепает ИСХОДНИКИ. Сеть приезжает
# транзитом из зависимости: FluidAudio несёт в себе загрузчик моделей, и никакой
# grep по нашим .swift этого не увидит.
#
# ЧЕСТНАЯ КАРТИНА, пересмотрена 05.09.2026:
#   1. У приложения РОВНО ОДИН путь в сеть — установка модели распознавания,
#      которую начинает человек кнопкой в знакомстве
#      (Sources/IrizDictate/SpeechModelInstaller.swift). Раньше пути не было
#      вовсе: модель ехала в образе. Возить в выпуске слепок модели значило
#      раздавать всем прошлогоднюю версию и полгигабайта сверху, и владелец
#      решил качать. Цена решения названа тут, а не спрятана.
#   2. В диктовке сеть по-прежнему запрещена: DownloadUtils.enforceOffline
#      снимается только на время явной установки и возвращается в defer.
#      Пока идёт диктовка, установка не начинается вовсе.
#   3. В собранном бинарнике 17 сетевых символов — все из загрузчика FluidAudio,
#      семейство URLSession и настройки прокси. Сырых сокетов и nw_* нет.
#   4. Приложение НЕ в песочнице — ему нужен Универсальный доступ и перехват
#      событий, а App Sandbox это запрещает. Значит сеть не запрещена системой,
#      она ограничена дисциплиной кода. Это надо говорить вслух, а не
#      прятать за словом «офлайн».
#
# Поэтому гейт делает две вещи:
#   A. Пинует базовый набор сетевых символов. Набор ВЫРОС — значит появился
#      новый путь в сеть, и это надо смотреть глазами.
#   B. Если приложение запущено — спрашивает ядро, есть ли у него сокеты.
#      Это единственная эмпирическая проверка обещания. Гонять её во время
#      установки модели бессмысленно: там сокеты и должны быть. Проверка
#      отвечает на вопрос «молчит ли приложение в обычной работе».
#
# Коды: 0 — чисто, 1 — набор изменился или найден живой сокет, 2 — проверить нечем.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

BASELINE_COUNT=17
# Набор пересчитан 05.09.2026, когда появился шаг установки модели: те же 17
# символов семейства URLSession, но теперь они реально вызываются.
BASELINE_SHA="0cb61e5abda7bb4188a17ca18fd3aa55ea10cd22034e4be4f5b9272a1392d7bb"
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
  echo "offline_binary_gate: символы — базовый набор без изменений ($COUNT, все из загрузчика FluidAudio)"
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
    echo "offline_binary_gate: сокетов нет — за $UP работы ни одного соединения (pid $PID)"
  fi
fi

exit "$status"
