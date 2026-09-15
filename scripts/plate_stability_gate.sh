#!/bin/bash
# Ворота устойчивости плашки: две съёмки подряд дают ОДИН И ТОТ ЖЕ кадр.
#
# Владелец 06.09.2026: «в очередной раз вижу глюк на самой плашке, она глючит и
# открывается по-разному и периодически криво». Жалоба повторялась, а спорить
# было не с чем: «по-разному» глазами не измеряется.
#
# Замер нашёл первую причину сразу: пять прогонов подряд разошлись на 97,8 %
# пикселей в форме «на записи». Плашку двигал сам прибор съёмки - сцена переноса
# тащила её в угол, отпускание сохраняло новое место в настройках, и каждая
# следующая съёмка начиналась с другой точки экрана.
#
# Форма «на записи» из сравнения исключена намеренно: в ней бежит волна, и
# пиксели обязаны отличаться. Сравниваются формы БЕЗ движения.
#
#   scripts/plate_stability_gate.sh            два прогона и сравнение
#   scripts/plate_stability_gate.sh --selftest проверка самих ворот
set -uo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/iriz.app/Contents/MacOS/iriz
STATIC_FORMS="plate-resting-light plate-resting-dark plate-hover-light plate-hover-dark plate-open-empty-light plate-open-empty-dark"

sravnit() {
    python3 - "$1" "$2" <<'PYCMP'
import sys
from PIL import Image, ImageChops
a, b = (Image.open(p).convert("RGB") for p in sys.argv[1:3])
if a.size != b.size:
    print(f"размер разошёлся: {a.size} против {b.size}")
    sys.exit(1)
diff = ImageChops.difference(a, b)
data = diff.get_flattened_data() if hasattr(diff, "get_flattened_data") else diff.getdata()
bad = sum(1 for p in data if sum(p) > 24)
share = bad / (a.size[0] * a.size[1])
# Порог не ноль: стекло сэмплирует подложку живьём, и единичные пиксели по
# кромке гуляют от кадра к кадру. Форма, съехавшая хоть на пункт, даёт проценты.
if share > 0.005:
    print(f"расхождение {share*100:.2f}%")
    sys.exit(1)
sys.exit(0)
PYCMP
}

if [ "${1:-}" = "--selftest" ]; then
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    ok=0
    python3 - "$TMP" <<'PYGEN'
import sys
from PIL import Image
d = sys.argv[1]
Image.new("RGB", (40, 20), (10, 20, 30)).save(f"{d}/a.png")
Image.new("RGB", (40, 20), (10, 20, 30)).save(f"{d}/b.png")
im = Image.new("RGB", (40, 20), (10, 20, 30))
for x in range(40):
    for y in range(20):
        im.putpixel((x, y), (200, 200, 200))
im.save(f"{d}/c.png")
PYGEN
    if sravnit "$TMP/a.png" "$TMP/b.png" >/dev/null; then
        echo "     OK  одинаковые кадры приняты"
    else
        echo "ПРОВАЛ: одинаковые кадры отвергнуты"; ok=1
    fi
    if sravnit "$TMP/a.png" "$TMP/c.png" >/dev/null; then
        echo "ПРОВАЛ: разные кадры не пойманы"; ok=1
    else
        echo "     OK  разные кадры отвергнуты"
    fi
    [ $ok -eq 0 ] && echo "SELFTEST OK"
    exit $ok
fi

if [ ! -x "$APP" ]; then
    echo "ВОРОТА ПЛАШКИ: нет собранного приложения" >&2
    echo "собери: bash scripts/build_app.sh" >&2
    exit 2
fi

ODIN=$(mktemp -d); DVA=$(mktemp -d)
trap 'rm -rf "$ODIN" "$DVA"' EXIT
"$APP" --capture-plate "$ODIN" >/dev/null 2>&1 || { echo "ВОРОТА ПЛАШКИ: первая съёмка не удалась" >&2; exit 1; }
"$APP" --capture-plate "$DVA" >/dev/null 2>&1 || { echo "ВОРОТА ПЛАШКИ: вторая съёмка не удалась" >&2; exit 1; }

FAIL=0
for form in $STATIC_FORMS; do
    if out=$(sravnit "$ODIN/$form.png" "$DVA/$form.png"); then
        echo "     OK  $form"
    else
        echo "  РАЗОШЛОСЬ $form: $out"
        FAIL=1
    fi
done

echo
if [ $FAIL -eq 0 ]; then
    echo "ВОРОТА ПЛАШКИ: форма повторяется от прогона к прогону"
else
    echo "ВОРОТА ПЛАШКИ: плашка открывается по-разному" >&2
fi
exit $FAIL
