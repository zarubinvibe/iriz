#!/bin/bash
# Тест scripts/dedup_dictations.sh на ВРЕМЕННОМ каталоге.
# Запуск: bash scripts/dedup_dictations_test.sh
# Хранилища владельца (~/Library/Application Support/smltlk) не касается ни одной командой:
# все прогоны идут с явным --root в mktemp -d.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/dedup_dictations.sh"
LIVE="$HOME/Library/Application Support/smltlk"
passed=0
failed=0

ok()   { printf 'OK: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; failed=$((failed + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 = $3"; else fail "$1: ожидалось «$3», получено «$2»"; fi; }

# Хранилище-макет: 3 уникальных текста, 5 папок (два дубля), плюс мусор, который
# перечислитель промпт-режима не видит: скрытая папка и папка без raw.txt.
make_store() {
  local root="$1" d
  mkdir -p "$root"
  chmod 700 "$root"
  new() { mkdir -p "$root/$1"; printf '%s' "$2" > "$root/$1/raw.txt"; chmod 700 "$root/$1"; chmod 600 "$root/$1/raw.txt"; }
  new 2026-08-04T10-00-00Z "текст один"
  new 2026-08-04T11-00-00Z "текст два"
  # Этой папке нарочно даны слабые права: она уедет в карантин, и проверка ниже
  # обязана увидеть 0700/0600 — перенос права не ослабляет, а подтягивает.
  chmod 755 "$root/2026-08-04T10-00-00Z"; chmod 644 "$root/2026-08-04T10-00-00Z/raw.txt"
  new 2026-08-05T12-00-00Z "текст один"   # дубль 10-00-00
  new 2026-08-05T13-00-00Z "текст три"
  new 2026-08-05T14-00-00Z "текст два"    # дубль 11-00-00, и это глобальный максимум
  mkdir -p "$root/.hidden"; printf 'x' > "$root/.hidden/raw.txt"
  mkdir -p "$root/no-raw"
  d="$root/2026-08-04T10-00-00Z"
  [ -f "$d/raw.txt" ] || { echo "макет не собрался" >&2; exit 2; }
}

count_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }

# Снимок дерева вместе с правами: ловит и перенос, и тихий chmod.
snapshot() { find "$1" -print0 | xargs -0 stat -f '%Sp %N' | LC_ALL=C sort; }

# ── 1. сухой прогон: считает верно и НИЧЕГО не двигает ────────────────────────
TMP1="$(mktemp -d)"
make_store "$TMP1/dictations"
before_listing="$(snapshot "$TMP1")"
dry_out="$(bash "$SCRIPT" --root "$TMP1/dictations")"
printf '%s\n' "$dry_out" | sed 's/^/  | /'
after_listing="$(snapshot "$TMP1")"

check "сухой прогон: всего" "$(printf '%s\n' "$dry_out" | sed -n 's/^Всего надиктовок: //p')" "5"
check "сухой прогон: уникальных" "$(printf '%s\n' "$dry_out" | sed -n 's/^Уникальных текстов (sha256 raw.txt): //p')" "3"
check "сухой прогон: дублей" "$(printf '%s\n' "$dry_out" | sed -n 's/^Дублей на перенос: //p')" "2"
if [ "$before_listing" = "$after_listing" ]; then
  ok "сухой прогон не сдвинул ни одного файла"
else
  fail "сухой прогон изменил дерево:"
  diff <(printf '%s\n' "$before_listing") <(printf '%s\n' "$after_listing") || true
fi
if find "$TMP1" -maxdepth 1 -name 'dictations-quarantine-*' | grep -q .; then
  fail "сухой прогон создал карантин"
else
  ok "сухой прогон карантин не создавал"
fi

# ── 2. перенос: дубли в карантине рядом, ничего не потеряно, права целы ────────
TMP2="$(mktemp -d)"
ROOT2="$TMP2/dictations"
make_store "$ROOT2"
apply_out="$(bash "$SCRIPT" --root "$ROOT2" --apply)"
printf '%s\n' "$apply_out" | sed 's/^/  | /'

QUAR="$(find "$TMP2" -maxdepth 1 -type d -name 'dictations-quarantine-*' | LC_ALL=C tail -1)"
if [ -n "$QUAR" ]; then ok "карантин создан: $(basename "$QUAR")"; else fail "карантин не создан"; fi

check "после переноса: осталось папок в хранилище" "$(count_dirs "$ROOT2")" "5"  # 3 уникальные + .hidden + no-raw
check "после переноса: видимых надиктовок" "$(printf '%s\n' "$apply_out" | sed -n 's/^Осталось в хранилище: \([0-9]*\).*/\1/p')" "3"
check "после переноса: перенесено" "$(printf '%s\n' "$apply_out" | sed -n 's/^Перенесено папок: //p')" "2"
check "в карантине папок" "$(count_dirs "$QUAR")" "2"

# уникальных текстов в хранилище == числу оставшихся надиктовок
uniq_left="$(find "$ROOT2" -mindepth 2 -maxdepth 2 -name raw.txt -not -path '*/.hidden/*' -exec shasum -a 256 {} + | cut -d' ' -f1 | LC_ALL=C sort -u | wc -l | tr -d ' ')"
check "уникальных текстов среди оставшихся" "$uniq_left" "3"

# карантин лежит СНАРУЖИ dictations/ — иначе перечислитель промпт-режима заберёт его
case "$QUAR" in
  "$ROOT2"/*) fail "карантин внутри dictations/: $QUAR" ;;
  "$TMP2"/*) ok "карантин снаружи dictations/, рядом с ним" ;;
  *) fail "карантин не там, где ждали: $QUAR" ;;
esac

# последняя надиктовка не изменилась: глобальный максимум остался на месте
check "последняя надиктовка ДО" "$(printf '%s\n' "$apply_out" | sed -n 's/^Последняя надиктовка (перечислитель промпт-режима) ДО: //p')" "2026-08-05T14-00-00Z"
check "последняя надиктовка ПОСЛЕ" "$(printf '%s\n' "$apply_out" | sed -n 's/^Последняя надиктовка (перечислитель промпт-режима) ПОСЛЕ: //p')" "2026-08-05T14-00-00Z"
if [ -d "$ROOT2/2026-08-05T14-00-00Z" ]; then ok "максимум по имени остался в хранилище"; else fail "максимум по имени уехал в карантин"; fi

# ничего не удалено: все пять исходных имён по-прежнему существуют
lost=0
for n in 2026-08-04T10-00-00Z 2026-08-04T11-00-00Z 2026-08-05T12-00-00Z 2026-08-05T13-00-00Z 2026-08-05T14-00-00Z; do
  if [ ! -d "$ROOT2/$n" ] && [ ! -d "$QUAR/$n" ]; then fail "папка исчезла: $n"; lost=$((lost + 1)); fi
done
if [ "$lost" -eq 0 ]; then ok "все 5 исходных папок на месте (хранилище + карантин)"; fi

# права не ослаблены
check "права карантина" "$(stat -f '%Lp' "$QUAR")" "700"
bad_dirs="$(find "$QUAR" -type d ! -perm 700 | wc -l | tr -d ' ')"
bad_files="$(find "$QUAR" -type f ! -perm 600 | wc -l | tr -d ' ')"
check "каталогов с правами не 0700 в карантине" "$bad_dirs" "0"
check "файлов с правами не 0600 в карантине" "$bad_files" "0"

# ── 3. повторный прогон: дублей больше нет ────────────────────────────────────
second="$(bash "$SCRIPT" --root "$ROOT2")"
check "повторный сухой прогон: дублей" "$(printf '%s\n' "$second" | sed -n 's/^Дублей на перенос: //p')" "0"

# ── 3б. предполётный прогноз последней надиктовки ─────────────────────────────
check "прогноз последней надиктовки в сухом прогоне" \
  "$(printf '%s\n' "$dry_out" | sed -n 's/^Последняя надиктовка после переноса (прогноз): //p')" \
  "2026-08-05T14-00-00Z"

# ── 4. валидация входа ────────────────────────────────────────────────────────
rc=0; bash "$SCRIPT" --root "$TMP2/нет-такого" >/dev/null 2>&1 || rc=$?
check "несуществующий --root даёт код 2" "$rc" "2"
rc=0; bash "$SCRIPT" --root >/dev/null 2>&1 || rc=$?
check "--root без значения даёт код 2" "$rc" "2"
rc=0; bash "$SCRIPT" --что-то >/dev/null 2>&1 || rc=$?
check "неизвестный аргумент даёт код 2" "$rc" "2"
TMP3="$(mktemp -d)"; mkdir -p "$TMP3/dictations"
rc=0; bash "$SCRIPT" --root "$TMP3/dictations" >/dev/null 2>&1 || rc=$?
check "пустое хранилище даёт код 2" "$rc" "2"

# ── 5. скрипт не умеет удалять ────────────────────────────────────────────────
if grep -nE '(^|[^[:alnum:]_./-])(rm|rmdir|unlink)([[:space:]]|$)' "$SCRIPT" | grep -v '^[[:space:]]*#'; then
  fail "в скрипте есть удаляющая команда"
else
  ok "в скрипте ни rm, ни rmdir, ни unlink"
fi

# ── 6. хранилище владельца не тронуто ─────────────────────────────────────────
if [ -d "$LIVE" ]; then
  if grep -q "$LIVE" <(printf '%s\n' "$before_listing" "$after_listing"); then
    fail "тест смотрел в живое хранилище"
  else
    ok "живое хранилище в тесте не участвовало"
  fi
fi

printf '\nИтог: %d OK, %d FAIL\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
