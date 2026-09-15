#!/bin/bash
# Ворота живого адреса: ни один скрипт не смеет обращаться к процессу или бандлу,
# которого не существует.
#
# Зачем. Переименование smltlk -> iriz оставило в gate_defects.sh «pgrep -qx smltlk»
# и «process "smltlk"», а в gate_app.sh - путь /Applications/smltlk.app. Ворота при
# этом не краснели: они честно докладывали «приложение не запущено» и оставались бы
# слепыми навсегда. Проверка, которая ищет несуществующее, хуже отсутствующей.
#
# Канон берётся из build_app.sh - оттуда, где имя реально задаётся, а не из константы
# рядом: иначе разъедется и канон.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=${1:-.}
BUILD="$ROOT/scripts/build_app.sh"
[ -f "$BUILD" ] || { echo "binary_name_gate: нет $BUILD" >&2; exit 2; }

APP_PATH=$(grep -m1 '^APP=/Applications/' "$BUILD" | sed 's|^APP=/Applications/||; s|\.app$||')
EXEC=$(grep -m1 'cp .build/release/.* "\$APP/Contents/MacOS/' "$BUILD" | sed 's|.*/MacOS/||; s|"$||')
[ -n "$APP_PATH" ] && [ -n "$EXEC" ] || { echo "binary_name_gate: не вычитал имя из build_app.sh" >&2; exit 2; }

fails=0
report() { echo "  $1"; fails=$((fails+1)); }

# Комментарии не адресуют ничего: сравниваем только код, иначе краснеет объяснение
# самого дефекта. Из pgrep/pkill берём лишь форму -x: -f матчит командную строку
# целиком, там имя процесса не при чём.
code() { sed 's/#.*//' "$1"; }

while IFS= read -r -d '' f; do
  # build_app.sh - источник канона. Тесты ворот несут мёртвые адреса нарочно,
  # как образцы враждебного входа: судить их - судить сам образец.
  case "$f" in *"/build_app.sh"|*_test.sh) continue;; esac
  while IFS= read -r name; do
    [ "$name" = "$EXEC" ] || report "$f: обращение к процессу «$name», установлен «$EXEC»"
  done < <(code "$f" | grep -oE '\b(pgrep|pkill) +-[a-zA-Z]*x[a-zA-Z]* +[A-Za-z0-9_.-]+' \
           | awk '{print $NF}' | sort -u)
  while IFS= read -r name; do
    [ "$name" = "$EXEC" ] || report "$f: osascript адресует процесс «$name», установлен «$EXEC»"
  done < <(code "$f" | grep -oE 'process "[A-Za-z0-9_.-]+"' | sed 's|process "||; s|"$||' | sort -u)
  while IFS= read -r name; do
    [ "$name" = "$APP_PATH" ] || report "$f: путь /Applications/$name.app, установлен «$APP_PATH.app»"
  done < <(code "$f" | grep -oE '/Applications/[A-Za-z0-9_.-]+\.app' | sed 's|/Applications/||; s|\.app$||' | sort -u)
done < <(find "$ROOT/scripts" -maxdepth 1 -name '*.sh' -print0)

if [ "$fails" -gt 0 ]; then
  echo "binary_name_gate: мёртвых адресов $fails - проверка искала бы несуществующее и молчала" >&2
  exit 1
fi
echo "binary_name_gate: OK - все адреса ведут на «$EXEC» / «$APP_PATH.app»"
