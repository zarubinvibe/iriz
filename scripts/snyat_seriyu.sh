#!/usr/bin/env bash
# Снять серию кадров ПО ОДНОМУ, подряд. Драйвер поверх snyat_kadr.sh.
#
#   scripts/snyat_seriyu.sh <имя> [<имя> ...]
#
# Для каждого имени берется .github/pantheon/<имя>-prompt.txt и снимается
# docs/assets/pantheon/<имя>.png. В референсы, кроме двух якорей канона, идут
# оба листа свода: без них каждая сцена придумывает фигуру и предметы заново.
# Уже снятый кадр пропускается, чтобы повтор прогона не стоил еще получаса.
set -uo pipefail

# Дом, по которому работает прибор. PANTHEON_DOM позволяет снимать серию для
# соседнего проекта семьи: кадры и свод живут в выпускаемом доме, а не там, где
# лежит скрипт.
DOM="$(cd "${PANTHEON_DOM:-$(dirname "$0")/..}" && pwd)"
# Снималка берётся РЯДОМ С ДРАЙВЕРОМ, а не в доме миссии. Иначе обещание PANTHEON_DOM
# («снимаем серию для соседнего проекта») ломается о собственную реализацию: у соседа
# scripts/snyat_kadr.sh нет и не должно быть - приборы выпуска живут в одном доме.
# Поймано 07.09.2026 на съёмке серии Койза: шесть отказов подряд «No such file or directory».
KADR="$(cd "$(dirname "$0")" && pwd)/snyat_kadr.sh"
[ -x "$KADR" ] || { echo "нет снималки кадра: $KADR" >&2; exit 2; }
SVOD_LICO="$DOM/docs/assets/pantheon/bible-character.png"
SVOD_REKVIZIT="$DOM/docs/assets/pantheon/bible-props.png"

for f in "$SVOD_LICO" "$SVOD_REKVIZIT"; do
  [ -f "$f" ] || { echo "свод не снят: $f" >&2; exit 2; }
done

otkazy=0
for imya in "$@"; do
  vyhod="$DOM/docs/assets/pantheon/$imya.png"
  if [ -s "$vyhod" ]; then
    echo "пропуск, кадр уже есть: $imya"
    continue
  fi
  "$KADR" \
    "$DOM/.github/pantheon/$imya-prompt.txt" \
    "$vyhod" \
    "$SVOD_LICO" "$SVOD_REKVIZIT" || otkazy=$((otkazy + 1))
done

if [ "$otkazy" -gt 0 ]; then
  echo "серия закончена с отказами: $otkazy" >&2
  exit 1
fi
echo "серия снята целиком"
