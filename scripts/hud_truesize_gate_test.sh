#!/bin/bash
# Враждебная проба ворот натуральной величины.
#
# Улика не «проба зелёная», а «проба краснеет, когда ворота ломают». Поэтому
# здесь четыре входа: честный, увеличенный, пустой и отсутствующий.
set -euo pipefail
cd "$(dirname "$0")/.."

gate="scripts/hud_truesize_gate.sh"
tmp=$(/usr/bin/mktemp -d)
trap 'rm -rf "$tmp"' EXIT

png() { # png <файл> <ширина> <высота>
  /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import sys, zlib, struct
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
raw = b"".join(b"\x00" + b"\x00\x00\x00\x00" * w for _ in range(h))
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
out = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw))
       + chunk(b"IEND", b""))
open(path, "wb").write(out)
PY
}

expect_green() {
  if ! "$gate" "$1" >/dev/null 2>&1; then
    echo "FAIL: ворота покраснели на честном входе ($2)"
    exit 1
  fi
}

expect_red() {
  if "$gate" "$1" >/dev/null 2>&1; then
    echo "FAIL: ворота пропустили $2"
    exit 1
  fi
}

# 1. Честный вход: два кадра приговора в натуральную величину.
ok="$tmp/ok"; mkdir -p "$ok"
png "$ok/look-01-dictation-dark.png" 248 74
png "$ok/look-02-prompt-dark.png" 248 74
png "$ok/motion-01-reveal-20.png" 992 296   # неприговорный кадр может быть любым
expect_green "$ok" "два кадра 248x74"

# 2. Увеличенный кадр приговора - ровно тот случай, который стоил пяти отказов.
big="$tmp/big"; mkdir -p "$big"
png "$big/look-01-dictation-dark.png" 248 74
png "$big/look-02-prompt-dark.png" 497 147
expect_red "$big" "кадр приговора 497x147"

# 3. Кадров приговора нет вовсе: судить нечего, значит не принято.
empty="$tmp/empty"; mkdir -p "$empty"
png "$empty/motion-01-reveal-20.png" 248 74
expect_red "$empty" "каталог без look-*.png"

# 4. Каталога нет.
expect_red "$tmp/нет-такого" "отсутствующий каталог"

# 5. Приложение говорит одно, кадры показывают другое. Ворота больше не грепают
#    строку в исходнике - они СПРАШИВАЮТ приложение, - поэтому враждебный вход
#    теперь такой: подставная сборка называет другие размеры.
home="$tmp/home"
mkdir -p "$home/scripts" "$home/.build/debug" "$home/frames"
cp "$gate" "$home/scripts/"
cat > "$home/.build/debug/iriz" <<'FAKE'
#!/bin/bash
[ "$1" = "hud-size" ] || exit 64
printf 'small 198 58\nmedium 248 74\nlarge 322 96\n'
FAKE
chmod +x "$home/.build/debug/iriz"
png "$home/frames/look-01-dictation-dark.png" 248 74

if ! "$home/scripts/hud_truesize_gate.sh" "$home/frames" >/dev/null 2>&1; then
  echo "FAIL: копия дома с честной сборкой покраснела"
  exit 1
fi

cat > "$home/.build/debug/iriz" <<'FAKE'
#!/bin/bash
[ "$1" = "hud-size" ] || exit 64
printf 'small 198 58\nmedium 320 74\nlarge 322 96\n'
FAKE
chmod +x "$home/.build/debug/iriz"

if "$home/scripts/hud_truesize_gate.sh" "$home/frames" >/dev/null 2>&1; then
  echo "FAIL: ворота пропустили расхождение кадра с тем, что обещает приложение"
  exit 1
fi

# 6. Кадр называет СВОЙ вариант: малый кадр судится по малому размеру, а не по
#    среднему. Иначе выбор размера нечем стеречь.
cat > "$home/.build/debug/iriz" <<'FAKE'
#!/bin/bash
[ "$1" = "hud-size" ] || exit 64
printf 'small 198 58\nmedium 248 74\nlarge 322 96\n'
FAKE
chmod +x "$home/.build/debug/iriz"
rm -f "$home/frames"/*.png
png "$home/frames/look-small-01-dictation.png" 198 58
png "$home/frames/look-large-01-dictation.png" 322 96
if ! "$home/scripts/hud_truesize_gate.sh" "$home/frames" >/dev/null 2>&1; then
  echo "FAIL: ворота покраснели на честных кадрах малого и большого размера"
  exit 1
fi
rm -f "$home/frames"/*.png
png "$home/frames/look-small-01-dictation.png" 248 74     # средний размер под именем малого
if "$home/scripts/hud_truesize_gate.sh" "$home/frames" >/dev/null 2>&1; then
  echo "FAIL: ворота пропустили кадр чужого размера"
  exit 1
fi

# 7. Сборки нет вовсе: ворота обязаны отказать, а не промолчать. Молчаливое
#    «нечего проверять» - ровно тот класс дефекта, из-за которого прежние
#    ворота ослепли на переименовании.
rm -f "$home/.build/debug/iriz"
png "$home/frames/look-01-dictation-dark.png" 248 74
if "$home/scripts/hud_truesize_gate.sh" "$home/frames" >/dev/null 2>&1; then
  echo "FAIL: ворота промолчали без собранного приложения"
  exit 1
fi

echo "OK: ворота натуральной величины краснеют на увеличенном, пустом и отсутствующем входе, на расхождении с приложением, на кадре чужого размера и без сборки"
