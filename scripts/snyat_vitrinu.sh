#!/usr/bin/env bash
# Снять витрину: собрать, снять все кадры, ужать без потери качества.
#
# Одна команда вместо трёх ручных шагов. Ручные шаги тут уже стоили дорого:
# кадры плашки копировали отдельно и они отстали на день, кадры страниц
# настроек снимали руками и они отстали на все правки владельца.
#
# Небундленный бинарь - не прихоть: у Iriz.app своя запись в разрешении
# «Запись экрана», самоподпись меняется на каждой сборке, и система молча
# отказывает бандлу.
#
#   scripts/snyat_vitrinu.sh            снять в docs/assets/shots
#   scripts/snyat_vitrinu.sh <папка>    снять в свою папку
#   scripts/snyat_vitrinu.sh --selftest проверить, что ужатие не портит кадр
set -uo pipefail
cd "$(dirname "$0")/.."

BINAR=./.build/release/IrizApp

ujat() {
    python3 - "$1" <<'PYOPT'
import os
import sys
from PIL import Image

# Пережатие БЕЗ потери качества: те же пиксели, лучше упакованы. Замер
# 07.09.2026 на кадре настроек: 706 112 байт против 356 021, то есть вдвое.
# Квантование до 256 цветов дало бы вчетверо, но полосит градиент подложки -
# ровно то место, ради которого подложка и появилась.
papka = sys.argv[1]
bylo = stalo = 0
for imya in sorted(os.listdir(papka)):
    if not imya.endswith(".png"):
        continue
    put = os.path.join(papka, imya)
    do = os.path.getsize(put)
    izobrazhenie = Image.open(put)
    snyat = lambda im: list(im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata())
    pikseli = snyat(izobrazhenie)
    izobrazhenie.save(put, "PNG", optimize=True)
    if snyat(Image.open(put)) != pikseli:
        print(f"ПЕРЕЖАТИЕ ИСПОРТИЛО КАДР: {imya}", file=sys.stderr)
        sys.exit(1)
    bylo += do
    stalo += os.path.getsize(put)
print(f"ужато: {bylo // 1024} КБ -> {stalo // 1024} КБ")
PYOPT
}

if [ "${1:-}" = "--selftest" ]; then
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    python3 - "$TMP" <<'PYGEN'
import sys
from PIL import Image
d = sys.argv[1]
im = Image.new("RGB", (200, 120))
for x in range(200):
    for y in range(120):
        im.putpixel((x, y), (x % 256, y % 256, (x * y) % 256))
im.save(f"{d}/proba.png")
PYGEN
    do_hash=$(shasum -a 256 "$TMP/proba.png" | cut -c1-16)
    if ujat "$TMP" >/dev/null; then
        echo "     OK  ужатие прошло и пиксели совпали"
    else
        echo "ПРОВАЛ: ужатие испортило кадр"; exit 1
    fi
    posle_hash=$(shasum -a 256 "$TMP/proba.png" | cut -c1-16)
    if [ "$do_hash" = "$posle_hash" ]; then
        echo "     .. файл не изменился, ужимать было нечего"
    else
        echo "     OK  файл действительно пережат"
    fi
    echo "SELFTEST OK"
    exit 0
fi

PAPKA="${1:-docs/assets/shots}"

echo "=== сборка"
swift build -c release --product IrizApp >/dev/null || { echo "сборка не прошла" >&2; exit 1; }

echo "=== съёмка"
"$BINAR" --capture-docs "$PAPKA" | tail -1 || { echo "съёмка не удалась" >&2; exit 1; }

echo "=== ужатие"
ujat "$PAPKA" || exit 1

echo "витрина снята: $(ls "$PAPKA"/*.png | wc -l | tr -d ' ') кадров, $(du -sh "$PAPKA" | cut -f1)"
