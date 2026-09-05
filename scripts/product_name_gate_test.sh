#!/bin/bash
# Враждебная проба ворот имени. Улика не «ворота зелёные», а «ворота краснеют
# на подписи и молчат на адресе»: в этом вся их работа.
set -uo pipefail
cd "$(dirname "$0")/.."
gate="$PWD/scripts/product_name_gate.sh"
tmp=$(/usr/bin/mktemp -d); trap 'rm -rf "$tmp"' EXIT

plant() {
  local d="$tmp/case-$RANDOM$RANDOM"; mkdir -p "$d"
  printf 'import Foundation\nlet title = "Настройки Ириды"\n' > "$d/A.swift"
  echo "$d"
}
green() { bash "$gate" "$1" >/dev/null 2>&1 || { echo "FAIL: покраснели на честном ($2)"; exit 1; }; }
red()   { bash "$gate" "$1" >/dev/null 2>&1 && { echo "FAIL: пропустили $2"; exit 1; }; return 0; }

d="$(plant)"; green "$d" "чистый исходник"

# Подпись со старым именем - красный.
d="$(plant)"; printf 'let hello = "Добро пожаловать в smltlk"\n' >> "$d/A.swift"
red "$d" "старое имя в подписи"

# Адрес со старым именем - зелёный: это контракт с диском, а не текст.
d="$(plant)"; printf 'let id = "ru.smltlk.app"\nlet dir = "Application Support/smltlk"\n' >> "$d/A.swift"
green "$d" "идентификатор и каталог данных"

# Комментарий не судится: там имя живёт как история.
d="$(plant)"; printf '// когда-то это называлось smltlk\n' >> "$d/A.swift"
green "$d" "имя в комментарии"

echo "OK: ворота имени краснеют на подписи и молчат на адресе"
