#!/bin/bash
# Гейт этапа 7 (приёмка): counters.json → последние 5 дней с ненулевым набором.
# Полоса: 25–55 автопереключений на 1000 слов (Punto = 38,4); отмен ≤ 3 %.
# Коды: 0 — приёмка пройдена, 1 — порог провален, 3 — данных недостаточно
# (это НЕ зелёный и НЕ красный: окно ещё не набрано, выдумывать вердикт нельзя).
set -uo pipefail

# Р-3 (RISKS.md): соперник за правый ⌘. Если рядом жив старый агент — Punto
# Switcher или SuperDictate — одно нажатие ловят два процесса: диктовка стартует
# дважды, раскладку правят оба, а виноватым выглядит новое приложение.
# Считать счётчики в таком окружении бессмысленно: цифры будут чужие.
#
# Ищем именно ИСПОЛНЯЕМЫЙ ФАЙЛ внутри .app, а не любое упоминание имени в
# командной строке: иначе гейт поймает компилятор, собирающий наш собственный
# SuperDictateImporter.swift, и будет врать красным на пустом месте.
RIVALS=""
for rival in "Punto Switcher" "SuperDictate" "Punto"; do
    if pgrep -qf "/Applications/${rival}.app/Contents/MacOS/" 2>/dev/null; then
        RIVALS="${RIVALS}${RIVALS:+, }${rival}"
    fi
done
if [ -n "$RIVALS" ]; then
    echo "ПРИЁМКА НЕВОЗМОЖНА: рядом работает $RIVALS."
    echo "Правый ⌘ и раскладку перехватывают два процесса сразу — замер будет не про нас."
    echo "Закройте соперника и повторите."
    exit 3
fi

COUNTERS="$HOME/Library/Application Support/smltlk/counters.json"
exec python3 - "$COUNTERS" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    print(f"ПРИЁМКА НЕВОЗМОЖНА: {path} отсутствует или не читается — счётчиков ещё нет.")
    sys.exit(3)

days = [d for d in data.get("days", []) if d.get("words", 0) > 0]
window = days[-5:]
words = sum(d.get("words", 0) for d in window)
autos = sum(d.get("autoswitches", 0) for d in window)
undos = sum(d.get("undos", 0) for d in window)

print(f"окно: {len(window)} дн. с набором (нужно 5), слов {words} (нужно >= 15000), "
      f"автопереключений {autos}, отмен {undos}")

if len(window) < 5 or words < 15000:
    print("ПРИЁМКА НЕВОЗМОЖНА: данных недостаточно. Это не провал и не успех — "
          "приёмочное окно ещё не набрано.")
    sys.exit(3)

rate = autos * 1000.0 / words
undo_rate = (undos / autos) if autos else 0.0
print(f"автопереключений на 1000 слов: {rate:.1f} (полоса 25-55, Punto = 38.4)")
print(f"отмен к автопереключениям: {undo_rate * 100:.2f}% (порог <= 3%)")

ok = True
if not (25 <= rate <= 55):
    print("ПРОВАЛ: частота автопереключений вне полосы.")
    ok = False
if undo_rate > 0.03:
    print("ПРОВАЛ: слишком много отмен.")
    ok = False
if ok:
    print("ПРИЁМКА ПРОЙДЕНА")
sys.exit(0 if ok else 1)
PY
