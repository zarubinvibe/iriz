#!/bin/bash
# Ворота целостности плашки: снятая форма помещается в свой кадр целиком.
#
# Владелец 07.09.2026, глядя на страницу знакомства: «вот тут, например, есть
# сломанная плашка, а на втором вообще плашки нет». Причину нашёл замер: панель
# расшифровки закрывалась, окно уже стояло размером капсулы, морф не шёл - и
# форму стекла никто не переприменял. Стекло оставалось прямоугольником панели
# 342x177 внутри окна 144x57, и окно резало его по кромке.
#
# Спорить с «плашка выглядит сломанной» глазами нельзя, поэтому здесь замер:
# свечение по контуру обязано иметь поле до края кадра. Кадр снимается по окну
# плюс поле, значит контур у самой кромки означает ровно одно - форму обрезало.
#
#   scripts/plate_whole_gate.sh            снять и проверить все статичные формы
#   scripts/plate_whole_gate.sh --selftest проверка самих ворот
set -uo pipefail
cd "$(dirname "$0")/.."

APP=./.build/release/IrizApp
# Формы БЕЗ переноса: сцена переноса снимает весь экран, у неё других правил.
FORMY="plate-resting-light plate-resting-dark plate-hover-light plate-hover-dark
       plate-listening-light plate-listening-dark plate-listening-hover-light
       plate-listening-hover-dark plate-recognizing-light plate-recognizing-dark
       plate-open-empty-light plate-open-empty-dark plate-open-text-light
       plate-open-text-dark plate-inserted-light plate-inserted-dark
       plate-failed-light plate-failed-dark"

proverit() {
    python3 - "$1" <<'PYCHK'
import statistics
import sys
from PIL import Image

# Кромка кадра обязана быть подложкой и только подложкой. Судим не по цвету
# контура (он зависит от палитры владельца), а по ОТКЛОНЕНИЮ от самой кромки:
# подложка - плавный градиент, её разброс мал. Замер 07.09.2026 на целых
# кадрах: максимум 13 из 255. Порог 30 держит запас вдвое и ловит любой контур.
POLE = 3
PREDEL = 30
NADO = 8

im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
tochki = []
for x in range(w):
    for y in list(range(POLE)) + list(range(h - POLE, h)):
        tochki.append(im.getpixel((x, y)))
for y in range(h):
    for x in list(range(POLE)) + list(range(w - POLE, w)):
        tochki.append(im.getpixel((x, y)))
sredina = tuple(statistics.median([p[i] for p in tochki]) for i in range(3))
chuzhie = [p for p in tochki if max(abs(p[i] - sredina[i]) for i in range(3)) > PREDEL]
if len(chuzhie) >= NADO:
    print(f"на кромке {len(chuzhie)} чужих точек при подложке {tuple(int(v) for v in sredina)}")
    sys.exit(1)
sys.exit(0)
PYCHK
}

if [ "${1:-}" = "--selftest" ]; then
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    ok=0
    python3 - "$TMP" <<'PYGEN'
import sys
from PIL import Image, ImageDraw
d = sys.argv[1]
# Честный кадр: контур с полем до края.
chesno = Image.new("RGB", (200, 100), (232, 234, 238))
ImageDraw.Draw(chesno).rounded_rectangle([20, 20, 179, 79], radius=30, outline=(90, 200, 120), width=3)
chesno.save(f"{d}/chesno.png")
# Порченый: тот же контур, но упирается в кромку.
porcheno = Image.new("RGB", (200, 100), (232, 234, 238))
ImageDraw.Draw(porcheno).rounded_rectangle([0, 0, 199, 99], radius=30, outline=(90, 200, 120), width=3)
porcheno.save(f"{d}/porcheno.png")
PYGEN
    if proverit "$TMP/chesno.png" >/dev/null; then
        echo "     OK  целая форма принята"
    else
        echo "ПРОВАЛ: целая форма отвергнута"; ok=1
    fi
    if proverit "$TMP/porcheno.png" >/dev/null; then
        echo "ПРОВАЛ: обрезанная форма не поймана"; ok=1
    else
        echo "     OK  обрезанная форма отвергнута"
    fi
    [ $ok -eq 0 ] && echo "SELFTEST OK"
    exit $ok
fi

if [ ! -x "$APP" ]; then
    echo "ВОРОТА ЦЕЛОСТНОСТИ: нет сборки $APP" >&2
    echo "собери: swift build -c release --product IrizApp" >&2
    exit 2
fi

KADRY=$(mktemp -d); trap 'rm -rf "$KADRY"' EXIT
# Небундленный бинарь: у Iriz.app своя запись в «Записи экрана», подпись меняется
# на каждой сборке, и screencapture молча отказывает бандлу.
"$APP" --capture-plate "$KADRY" >/dev/null 2>&1 || {
    echo "ВОРОТА ЦЕЛОСТНОСТИ: съёмка не удалась" >&2; exit 1; }

FAIL=0
for forma in $FORMY; do
    if [ ! -f "$KADRY/$forma.png" ]; then
        echo "  НЕТ КАДРА $forma"; FAIL=1; continue
    fi
    if out=$(proverit "$KADRY/$forma.png"); then
        echo "     OK  $forma"
    else
        echo "  ОБРЕЗАНА $forma: $out"; FAIL=1
    fi
done

[ $FAIL -eq 0 ] && echo "ВОРОТА ЦЕЛОСТНОСТИ: все формы целиком в кадре"
exit $FAIL
