#!/bin/bash
# Ворота натуральной величины плашки.
#
# Владелец отказал пять раз подряд, и причина была не во вкусе: раскадровка
# несла зашитый `pixelScale = 4`, а правило «приговор только в натуральную
# величину» пять раз жило в прозе хэндоффа и ни разу в коде. Здесь оно стоит
# машиной.
#
# Числа берутся из САМОГО приложения - `smltlk hud-size` зовёт ту же функцию
# dictationHUDVerdictPixelSize, по которой живёт плашка. Прежде ворота грепали
# строку с константой в исходнике и считали произведение сами; это была вторая
# копия арифметики, и она ослепла ровно тогда, когда константу переименовали:
# ворота доложили «не найдено» и не стали судить кадры вовсе.
#
# Гейт судит СВЯЗЬ: каждый кадр приговора обязан совпасть с тем размером,
# который приложение обещает для СВОЕГО варианта. Имя кадра называет вариант:
# `look-<вариант>-*.png`, а `look-*.png` без варианта судится по среднему.
#
# Использование: scripts/hud_truesize_gate.sh [каталог-кадров] [префикс]
set -euo pipefail
cd "$(dirname "$0")/.."

frames_dir="${1:-.build/hudframes}"
prefix="${2:-look-}"

fail() {
  echo "ОТКАЗ: $1" >&2
  exit 1
}

CLI=.build/debug/iriz
[ -x "$CLI" ] || CLI=.build/release/iriz
[ -x "$CLI" ] || fail "нет собранного $CLI - сначала swift build"

sizes=$("$CLI" hud-size) || fail "smltlk hud-size не отработал"
[ -n "$sizes" ] || fail "smltlk hud-size ничего не напечатал"

size_for() { # <вариант> -> "ширина высота"
  echo "$sizes" | /usr/bin/awk -v want="$1" '$1 == want { print $2, $3 }'
}

read -r default_w default_h < <(size_for medium)
[ -n "$default_w" ] || fail "приложение не назвало размер варианта medium"

shopt -s nullglob
verdict=("$frames_dir"/${prefix}*.png)
shopt -u nullglob

if [ "${#verdict[@]}" -eq 0 ]; then
  fail "в $frames_dir нет ни одного кадра приговора ${prefix}*.png - судить нечего"
fi

bad=0
for png in "${verdict[@]}"; do
  name=$(basename "$png")
  want_w=$default_w
  want_h=$default_h
  for choice in small medium large; do
    case "$name" in
      "${prefix}${choice}"*)
        read -r want_w want_h < <(size_for "$choice")
        ;;
    esac
  done
  read -r w h < <(/usr/bin/sips -g pixelWidth -g pixelHeight "$png" 2>/dev/null \
    | /usr/bin/awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w, h}')
  if [ "$w" != "$want_w" ] || [ "$h" != "$want_h" ]; then
    echo "  $name: ${w} x ${h}, а приложение обещает ${want_w} x ${want_h}" >&2
    bad=$((bad + 1))
  fi
done

if [ "$bad" -gt 0 ]; then
  fail "$bad из ${#verdict[@]} кадров приговора не в натуральную величину"
fi

echo "OK: ${#verdict[@]} кадров приговора совпали с размерами приложения ($(echo "$sizes" | tr '\n' ';' | sed 's/;$//'))"
