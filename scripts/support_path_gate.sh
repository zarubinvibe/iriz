#!/bin/bash
# Ворота единственного адреса каталога данных.
#
# Имя каталога знает ровно одна функция - irizApplicationSupportDirectory().
# Она же умеет перевезти данные со старого имени. Любая вторая сборка того же
# пути своими руками делает переименование половинчатым: так и вышло живьём -
# всё приложение переехало на iriz, а снимок состояния продолжал дописывать
# status.json в smltlk и воскрешал мёртвый каталог.
#
# Судим факт: никто, кроме самой функции, не приклеивает имя каталога к
# applicationSupportDirectory.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=${1:-.}
HOME_FILE="$ROOT/Sources/IrizCore/PrivateFiles.swift"
[ -f "$HOME_FILE" ] || { echo "support_path_gate: нет $HOME_FILE" >&2; exit 2; }

bad=0
while IFS= read -r -d '' file; do
  [ "$file" = "$HOME_FILE" ] && continue
  # Строка, где в одном выражении и applicationSupportDirectory, и склейка пути.
  if grep -n "applicationSupportDirectory" "$file" | grep -q .; then
    if grep -A3 "applicationSupportDirectory" "$file" | grep -q "appendingPathComponent"; then
      echo "  $file: собирает путь каталога данных сам" >&2
      bad=$((bad + 1))
    fi
  fi
done < <(find "$ROOT/Sources" -name '*.swift' -print0)

if [ "$bad" -gt 0 ]; then
  echo "support_path_gate: копий адреса $bad - переименование однажды останется половинчатым" >&2
  exit 1
fi
echo "support_path_gate: OK - имя каталога данных знает только irizApplicationSupportDirectory"
