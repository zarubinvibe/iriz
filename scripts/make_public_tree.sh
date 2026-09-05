#!/usr/bin/env bash
# Материализует кандидата на публикацию из белого списка — и ничего больше.
#
# Этот скрипт НЕ создаёт репозиторий, НЕ коммитит и НЕ пушит. Он собирает дерево
# и говорит, чистое оно или нет. Необратимое делает человек, отдельной командой,
# после того как посмотрел на результат.
#
# Правило безопасности: копируется ТОЛЬКО перечисленное в release/WHITELIST.txt.
# Всё остальное отсутствует по построению, а не потому, что его отфильтровали.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
WHITELIST="release/WHITELIST.txt"
OUT="${1:-}"

if [ -z "$OUT" ]; then
  echo "использование: scripts/make_public_tree.sh <каталог-назначения>" >&2
  exit 2
fi

if [ ! -f "$WHITELIST" ]; then
  echo "НЕТ БЕЛОГО СПИСКА: $WHITELIST" >&2
  echo "Без него публиковать нечего — список и есть гарантия." >&2
  exit 1
fi

# Отказ вместо молчаливой перезаписи: каталог назначения должен быть новым.
if [ -e "$OUT" ]; then
  echo "КАТАЛОГ УЖЕ СУЩЕСТВУЕТ: $OUT" >&2
  echo "Удалите его сами, осознанно. Скрипт чужого не трёт." >&2
  exit 1
fi

mkdir -p "$OUT"

copied=0
missing=0
while IFS= read -r line || [ -n "$line" ]; do
  # комментарии и пустые строки
  case "$line" in
    ''|'#'*) continue ;;
  esac

  # Защита от выхода за корень: '..' в белом списке — ошибка, не путь.
  case "$line" in
    /*|*..*)
      echo "НЕДОПУСТИМЫЙ ПУТЬ В СПИСКЕ: $line" >&2
      exit 1
      ;;
  esac

  # Каталожный префикс — жёсткая ошибка, а не удобство. Пока рекурсивное
  # копирование каталогов было разрешено, «белый список» перечислял 9 файлов из
  # 114: всё, что кто угодно клал в Sources/ или Tests/, публиковало себя само.
  # Список обязан быть пофайловым, иначе он ничего не гарантирует.
  if [ "${line%/}" != "$line" ]; then
    echo "КАТАЛОЖНЫЙ ПРЕФИКС В СПИСКЕ: $line" >&2
    echo "Белый список пофайловый. Перечислите файлы по одному." >&2
    exit 1
  fi

  if [ ! -f "$ROOT/$line" ]; then
    echo "  нет файла: $line" >&2
    missing=$((missing + 1))
    continue
  fi
  mkdir -p "$OUT/$(dirname "$line")"
  cp -p "$ROOT/$line" "$OUT/$line"
  copied=$((copied + 1))
done < "$WHITELIST"

echo "скопировано файлов: $copied"
[ "$missing" -gt 0 ] && echo "пропущено записей списка: $missing (см. выше)"

# Рабочий .gitignore публиковать нельзя: он перечисляет спрятанные каталоги
# поимённо и тем работает указателем — «вот что тут было». В дереве с нулевой
# историей их не существует, так что список бесполезен и вреден одновременно.
if [ -f release/public.gitignore ]; then
  cp -p release/public.gitignore "$OUT/.gitignore"
  echo "подменён .gitignore на публичный (без карты приватного дерева)"
else
  echo "НЕТ release/public.gitignore — рабочий .gitignore публиковать нельзя" >&2
  exit 1
fi

# Ни одного каталога рабочей истории проекта в кандидате быть не может.
# Проверяем явно: белый список мог быть отредактирован неаккуратно.
FORBIDDEN="00_brief 00_tcc 01_diverge 02_council 03_impl 04_merge 04_review 05_next graphify-out .kimi-runs .claude_private .build catalog soul"
leak=0
for d in $FORBIDDEN; do
  if [ -e "$OUT/$d" ]; then
    echo "УТЕЧКА КАТАЛОГА: $d попал в кандидата" >&2
    leak=1
  fi
done
if [ "$leak" -ne 0 ]; then
  echo "ОТКАЗ: рабочая история проекта не публикуется." >&2
  exit 1
fi

# Гейт приватности — если он есть, он решающий.
if [ -x scripts/release_privacy_gate.sh ]; then
  echo "--- гейт приватности ---"
  if ! bash scripts/release_privacy_gate.sh "$OUT"; then
    echo "ГЕЙТ КРАСНЫЙ: кандидат собран в $OUT, но публиковать его нельзя." >&2
    exit 1
  fi
else
  echo "ВНИМАНИЕ: scripts/release_privacy_gate.sh отсутствует." >&2
  echo "Кандидат собран, но машинной проверки приватности не было." >&2
  exit 1
fi

echo
echo "кандидат готов: $OUT"
echo "гейт зелёный. Дальше — глазами, потом руками:"
echo "  git -C $OUT init && git -C $OUT add -A && git -C $OUT commit -m 'initial public release'"
echo "  gh repo create <имя> --public --source $OUT --push"
