#!/bin/bash
# Ворота постоянства плашки.
#
# Решение владельца 06.09.2026: «Она должна быть всегда». Прежде плашка была
# событийной по устройству - у автомата было ровно два исхода, «показать
# стадию» и «пусто», а пусто для презентера значит снос окна. Правило «всегда»
# в прозе не держится: следующая правка презентера вернёт снос, и все пробы
# останутся зелёными, потому что судят они стадии, а не постоянство.
#
# Судим ПРИГОВОР САМОГО ПРИЛОЖЕНИЯ, а не исходник. `iriz hud-presence` зовёт ту
# же dictationHUDPresentation, по которой живёт продукт, и перебирает все пары
# «состояние конвейера × что сейчас на экране». Греп по исходнику ослеп бы на
# первом переименовании - этой ценой в доме уже платили воротами величины.
#
# Использование: scripts/hud_always_on_gate.sh [--selftest]
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "ОТКАЗ: $1" >&2
  exit 1
}

judge() { # <вывод приговора> -> 0 зелено, 1 красно
  local report="$1"
  [ -n "$report" ] || return 1
  # Ни одной пары, на которой плашка исчезает.
  if echo "$report" | grep -q ' hidden$'; then return 1; fi
  # И покой не уходит по таймеру: иначе «всегда» кончится через две секунды.
  echo "$report" | grep -qx 'resting lifetime never' || return 1
  # Приговор обязан быть непустым по делу, а не одной строкой про срок жизни.
  [ "$(echo "$report" | grep -c ' visible$')" -ge 30 ] || return 1
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  honest=$(printf 'ready none visible\nrecording listening visible\nresting lifetime never\n')
  for i in $(seq 1 40); do honest="ready s$i visible"$'\n'"$honest"; done
  judge "$honest" || fail "самопроверка: honest приговор признан красным"

  fallen=$(echo "$honest" | sed 's/^ready none visible$/ready none hidden/')
  judge "$fallen" && fail "самопроверка: исчезающая плашка признана зелёной"

  timed=$(echo "$honest" | sed 's/^resting lifetime never$/resting lifetime 2.0/')
  judge "$timed" && fail "самопроверка: покой со сроком жизни признан зелёным"

  judge "" && fail "самопроверка: пустой приговор признан зелёным"

  # Тощий приговор - тоже отказ: приложение, назвавшее две пары вместо всех,
  # ничего не доказало.
  judge "$(printf 'ready none visible\nresting lifetime never\n')" \
    && fail "самопроверка: тощий приговор признан зелёным"
  echo "самопроверка ворот постоянства: чисто"
  exit 0
fi

CLI=.build/debug/iriz
[ -x "$CLI" ] || CLI=.build/release/iriz
[ -x "$CLI" ] || fail "нет собранного $CLI - сначала swift build"

report=$("$CLI" hud-presence) || fail "iriz hud-presence не отработал"

if ! judge "$report"; then
  echo "$report" | grep ' hidden$' >&2 || true
  fail "плашка исчезает или покой уходит по таймеру - см. строки выше"
fi

echo "ворота постоянства плашки: чисто ($(echo "$report" | grep -c ' visible$') пар видимы)"
