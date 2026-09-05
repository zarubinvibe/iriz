#!/bin/bash
# Ворота имени продукта.
#
# Владелец увидел в готовом интерфейсе старое имя и сказал, что его быть не
# должно. Оно уцелело именно потому, что жило литералами по файлам: правило
# «переименовали» было в голове, а не в машине.
#
# Гейт судит только ВИДИМЫЙ текст - строки, которые владелец читает глазами.
# Контракты с диском и системой он не трогает: идентификатор бандла, каталог
# данных, ключи UserDefaults, формат файла словаря, имя лога, имена функций
# Metal и домены NSError - это адреса, а не подписи. Переезд по ним идёт
# отдельной работой с миграцией.
set -uo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-Sources}"

bad=$(/usr/bin/python3 - "$SRC" <<'PYEOF'
import pathlib, re, sys

# Что считается адресом, а не подписью, и потому имени не меняет.
ALLOW = re.compile(
    r'ru\.smltlk|com\.local|Application Support|smltlk-selfsign|CFBundle'
    r'|smltlk-dictate|smltlk-dictionary|smltlkWave|smltlk\.Dictation'
    r'|"smltlk"'
    r'|/smltlk|smltlk\.app|IrizApp|SMLTLK_|IrizDictateLogger'
    r'|smltlk-codex|smltlk root|smltlk/dictations'
)
# Литерал строки в Swift.
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')

bad = []
for path in sorted(pathlib.Path(sys.argv[1]).rglob("*.swift")):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        for literal in STRING.findall(line):
            if "smltlk" not in literal.lower():
                continue
            if ALLOW.search(literal):
                continue
            bad.append(f"{path}:{number}: {literal}")
print("\n".join(bad))
PYEOF
)

if [ -n "$bad" ]; then
  echo "ОТКАЗ: старое имя в видимом тексте:" >&2
  echo "$bad" >&2
  exit 1
fi
echo "OK: в видимом тексте старого имени нет"
