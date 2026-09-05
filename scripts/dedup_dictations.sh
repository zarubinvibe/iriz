#!/bin/bash
# Дубли надиктовок → карантин. Ничего не удаляется.
#
# Импорт из старого приложения прошёл дважды: один и тот же текст лежит в двух папках.
# Окно истории показало бы каждую запись дважды, и владелец решил бы, что оно сломано.
#
# ПОЧЕМУ КАРАНТИН, А НЕ УДАЛЕНИЕ.
# Это расшифровки речи владельца, включая процессуальные тексты. Удаление необратимо,
# и решение не наше. В скрипте нет ни одного `rm` и ни одного `rmdir` — только `mv`.
# Скрипт, который умеет удалять, когда-нибудь удалит. Поэтому и без временных файлов:
# всё считается в памяти, чистить нечего.
#
# ПОЧЕМУ КАРАНТИН ЛЕЖИТ РЯДОМ С dictations/, А НЕ ВНУТРИ.
# Перечислитель промпт-режима (Sources/IrizPrompt/PromptEnvelope.swift, latestDictation)
# собирает ПОДПАПКИ dictations/ по наличию raw.txt и берёт максимум по имени папки.
# Карантин внутри dictations/ попал бы в перечисление, и «последняя надиктовка» молча
# уехала бы в него. Префикс `_` не спасает: опция перечисления — .skipsHiddenFiles,
# а `_` не делает файл скрытым.
#
# КАКОЙ ЭКЗЕМПЛЯР ОСТАЁТСЯ: СТАРШИЙ ПО СОРТИРОВКЕ ИМЁН (максимальное имя в группе).
# Дубли определяются по sha256 содержимого raw.txt — байт в байт, без нормализации.
# Ключ решения — ИМЯ папки, а не mtime: имя и есть отметка времени надиктовки (ISO8601),
# оно не меняется, когда что-то тронуло файл, а mtime после импорта врёт (импорт нумерует
# папки назад от текущего момента, но пишет свежие первыми — по mtime «последней»
# оказывается самая старая запись; то же объяснение стоит в latestDictation).
# Остаётся папка с МАКСИМАЛЬНЫМ именем именно потому, что перечислитель берёт максимум
# по имени: так «последняя надиктовка» до и после переноса — одна и та же папка. Оставляли
# бы младшую — максимум уехал бы в карантин, и приложение показало бы владельцу вместо
# последней надиктовки запись суточной давности. На живых данных это не гипотеза:
# глобальный максимум (2026-08-05T18:34:28Z) — как раз дубль.
#
# Сухой прогон по умолчанию: без --apply не двигается ничего.
#
# Использование: scripts/dedup_dictations.sh [--apply] [--root <папка dictations>]
# Коды возврата: 0 — успех, 1 — проверка не сошлась, 2 — ошибка входа.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DEFAULT="$HOME/Library/Application Support/smltlk/dictations"
ROOT="$ROOT_DEFAULT"
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --root)
      if [ $# -lt 2 ]; then echo "Ошибка: --root без значения" >&2; exit 2; fi
      ROOT="$2"; shift 2 ;;
    -h|--help)
      echo "Использование: $0 [--apply] [--root <папка dictations>]"
      exit 0 ;;
    *) echo "Ошибка: неизвестный аргумент «$1»" >&2; exit 2 ;;
  esac
done

# ── валидация входа ───────────────────────────────────────────────────────────
if [ -z "$ROOT" ]; then echo "Ошибка: пустой путь к хранилищу" >&2; exit 2; fi
if [ ! -d "$ROOT" ]; then echo "Ошибка: нет каталога надиктовок: $ROOT" >&2; exit 2; fi
if [ ! -r "$ROOT" ] || [ ! -x "$ROOT" ]; then echo "Ошибка: каталог не читается: $ROOT" >&2; exit 2; fi
PARENT="$(cd "$(dirname "$ROOT")" && pwd)"
if [ ! -w "$PARENT" ]; then echo "Ошибка: родительский каталог не пишется: $PARENT" >&2; exit 2; fi

if command -v shasum >/dev/null 2>&1; then
  SHA=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then
  SHA=(sha256sum)
else
  echo "Ошибка: нет ни shasum, ни sha256sum" >&2; exit 2
fi

# ── перечисление по правилам latestDictation ──────────────────────────────────
# Подпапка учитывается, если она непосредственный ребёнок ROOT, не скрытая (не с точки —
# так же, как .skipsHiddenFiles) и содержит raw.txt. Прочее для промпт-режима не существует.
list_dirs() {
  local d name
  for d in "$1"/*; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in .*) continue ;; esac
    [ -f "$d/raw.txt" ] || continue
    printf '%s\n' "$name"
  done
}

# Что перечислитель промпт-режима считает последней надиктовкой: максимум по имени.
latest_name() { list_dirs "$1" | LC_ALL=C sort | tail -1; }

count_dirs() { list_dirs "$1" | wc -l | tr -d ' '; }

NAMES=()
while IFS= read -r name; do
  NAMES+=("$name")
done < <(list_dirs "$ROOT" | LC_ALL=C sort)

TOTAL=${#NAMES[@]}
if [ "$TOTAL" -eq 0 ]; then
  echo "Ошибка: в $ROOT нет ни одной папки с raw.txt" >&2
  exit 2
fi

# «хеш<TAB>имя», отсортировано: сначала по хешу, внутри группы имена по возрастанию.
# Значит последняя строка группы — та, что остаётся, всё до неё — дубли.
KEEP=()
DUP=()
prev_hash=""
prev_name=""
while IFS= read -r line; do
  hash="${line%%$'\t'*}"
  name="${line#*$'\t'}"
  if [ -n "$prev_name" ]; then
    if [ "$hash" = "$prev_hash" ]; then DUP+=("$prev_name"); else KEEP+=("$prev_name"); fi
  fi
  prev_hash="$hash"
  prev_name="$name"
done < <(
  for name in "${NAMES[@]}"; do
    hash="$("${SHA[@]}" "$ROOT/$name/raw.txt" | cut -d' ' -f1)"
    printf '%s\t%s\n' "$hash" "$name"
  done | LC_ALL=C sort
)
if [ -n "$prev_name" ]; then KEEP+=("$prev_name"); fi

UNIQUE=${#KEEP[@]}
DUPES=${#DUP[@]}
LATEST_BEFORE="$(latest_name "$ROOT")"

echo "Хранилище: $ROOT"
echo "Всего надиктовок: $TOTAL"
echo "Уникальных текстов (sha256 raw.txt): $UNIQUE"
echo "Дублей на перенос: $DUPES"
echo "Последняя надиктовка (перечислитель промпт-режима) ДО: $LATEST_BEFORE"

# Сверка с самим приложением: только для живого хранилища и только если бинарь собран.
# `smltlk prompt` без --dir читает то же хранилище и печатает путь к сырью канона.
# Из вывода берём ТОЛЬКО имя папки из строки пути — расшифровку речи в консоль не льём.
if [ "$ROOT" = "$ROOT_DEFAULT" ]; then
  BIN=""
  for candidate in "$REPO/.build/release/smltlk" "$REPO/.build/debug/smltlk"; do
    if [ -x "$candidate" ]; then BIN="$candidate"; break; fi
  done
  if [ -n "$BIN" ]; then
    envelope="$("$BIN" prompt 2>/dev/null || true)"
    seen="$(printf '%s\n' "$envelope" | sed -n '1,3s|.*/dictations/\([^/]*\)/raw\.txt.*|\1|p' | LC_ALL=C tail -1)"
    if [ -z "$seen" ]; then
      echo "Сверка с приложением: пропущена — «smltlk prompt» не назвал папку сырья"
    elif [ "$seen" = "$LATEST_BEFORE" ]; then
      echo "Сверка с «smltlk prompt»: совпадает ($seen)"
    else
      echo "Сверка с «smltlk prompt»: РАСХОЖДЕНИЕ — приложение видит $seen" >&2
      exit 1
    fi
  else
    echo "Сверка с приложением: пропущена — бинарь smltlk не собран (swift build)"
  fi
fi

if [ "$DUPES" -eq 0 ]; then
  echo "Дублей нет, делать нечего."
  exit 0
fi

echo "--- дубли (уехали бы в карантин) ---"
printf '%s\n' "${DUP[@]}"
echo "--- остаётся $UNIQUE папок; из каждой группы дублей остаётся старшая по сортировке имён ---"

# Предполётная проверка, ДО первого mv: что перечислитель увидит последней надиктовкой
# после переноса. Обязано совпасть с «ДО» — иначе правило выбора экземпляра сломано,
# и переносить нельзя: владелец увидел бы вместо последней надиктовки старую.
LATEST_PLANNED="$(printf '%s\n' "${KEEP[@]}" | LC_ALL=C sort | tail -1)"
echo "Последняя надиктовка после переноса (прогноз): $LATEST_PLANNED"
if [ "$LATEST_PLANNED" != "$LATEST_BEFORE" ]; then
  echo "ОШИБКА: перенос увёл бы последнюю надиктовку ($LATEST_BEFORE → $LATEST_PLANNED)." >&2
  echo "Ничего не тронуто. Разбираться с правилом выбора экземпляра." >&2
  exit 1
fi

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "СУХОЙ ПРОГОН: ничего не перенесено. Для настоящего переноса добавь --apply."
  after="$(count_dirs "$ROOT")"
  if [ "$after" -ne "$TOTAL" ]; then
    echo "ОШИБКА: число папок изменилось ($TOTAL → $after)" >&2
    exit 1
  fi
  echo "Проверка после сухого прогона: на диске по-прежнему $after папок."
  exit 0
fi

# ── перенос ───────────────────────────────────────────────────────────────────
QUARANTINE="$PARENT/dictations-quarantine-$(date -u +%Y-%m-%dT%H-%M-%SZ)"
if [ -e "$QUARANTINE" ]; then echo "Ошибка: карантин уже существует: $QUARANTINE" >&2; exit 2; fi
mkdir -m 700 "$QUARANTINE"
echo "Карантин: $QUARANTINE (рядом с dictations/, не внутри)"

moved=0
for name in "${DUP[@]}"; do
  if [ -e "$QUARANTINE/$name" ]; then echo "Ошибка: в карантине уже есть $name" >&2; exit 1; fi
  mv "$ROOT/$name" "$QUARANTINE/$name"
  # Права не ослабляются: снимаем групповые и прочие биты, владельческие не трогаем.
  chmod -R go-rwx "$QUARANTINE/$name"
  moved=$((moved + 1))
done
echo "Перенесено папок: $moved"

# ── проверка после ────────────────────────────────────────────────────────────
rc=0
LATEST_AFTER="$(latest_name "$ROOT")"
echo "Последняя надиктовка (перечислитель промпт-режима) ПОСЛЕ: $LATEST_AFTER"
if [ "$LATEST_AFTER" != "$LATEST_BEFORE" ]; then
  echo "ОШИБКА: последняя надиктовка изменилась ($LATEST_BEFORE → $LATEST_AFTER)" >&2
  rc=1
fi

REMAIN="$(count_dirs "$ROOT")"
echo "Осталось в хранилище: $REMAIN (уникальных текстов было $UNIQUE)"
if [ "$REMAIN" -ne "$UNIQUE" ]; then
  echo "ОШИБКА: осталось $REMAIN, ожидалось $UNIQUE" >&2
  rc=1
fi
if [ "$((REMAIN + moved))" -ne "$TOTAL" ]; then
  echo "ОШИБКА: папки потеряны: $REMAIN + $moved ≠ $TOTAL" >&2
  rc=1
fi

# Права в карантине: ни у одного объекта нет битов группы и прочих (то есть 0700/0600).
loose="$(find "$QUARANTINE" -perm +077 | wc -l | tr -d ' ')"
if [ "$loose" -eq 0 ]; then
  echo "Права в карантине: каталоги 0700, файлы 0600 — в порядке"
else
  echo "ОШИБКА: в карантине $loose объектов с ослабленными правами" >&2
  rc=1
fi

exit "$rc"
