#!/bin/bash
# Ворота перевода интерфейса.
#
# Непереведённая строка не ломает сборку и не падает в лог: она просто
# показывается по-русски человеку, который русского не знает. Такой дефект
# находит пользователь, а не разработчик, и находит он его молча - закрыв
# приложение.
#
# Три правила:
#   T01  каждый ключ из кода присутствует в каждой таблице;
#   T02  ни одна строка нерусской таблицы не осталась русской;
#   T03  экранированные последовательности не потеряны при переводе;
#   T04  таблица читается системой вообще.
#
# T04 добавлено 06.09.2026 по живому дефекту. Один незаэкранированный апостроф
# ломает НЕ строку, а ВСЮ таблицу: система молча отдаёт пусто, и весь язык
# показывается по-русски. Так и вышло с английским: три строки с кавычками
# внутри текста погасили весь английский интерфейс, и увидеть это можно было
# только кадром. Проверяется тем же plutil, которым таблицу читает система.
set -uo pipefail
cd "$(dirname "$0")/.."

EN=Sources/IrizCore/Resources/en.lproj/Localizable.strings
ZH=Sources/IrizCore/Resources/zh-Hans.lproj/Localizable.strings

check() {
    python3 - "$EN" "$ZH" <<'PY'
import re, subprocess, sys

en_path, zh_path = sys.argv[1], sys.argv[2]
rc = 0

out = subprocess.run(["python3", "scripts/collect_strings.py"],
                     capture_output=True, text=True).stdout
keys = {}
for line in out.split("\n"):
    if "\t" in line:
        key, original = line.split("\t", 1)
        keys[key.strip()] = original.strip()

CYRILLIC = re.compile(r"[а-яА-ЯёЁ]")
ROW = re.compile(r'^"([^"]+)"\s*=\s*"(.*)";\s*$')

for path, name in ((en_path, "en"), (zh_path, "zh")):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        print(f"T01: таблицы {name} нет вовсе")
        rc = 1
        continue
    table = {}
    for line in text.split("\n"):
        match = ROW.match(line.strip())
        if match:
            table[match.group(1)] = match.group(2)

    missing = sorted(set(keys) - set(table))
    if missing:
        print(f"T01: в таблице {name} нет ключей: {', '.join(missing[:5])}"
              + (f" и ещё {len(missing) - 5}" if len(missing) > 5 else ""))
        rc = 1

    russian = [k for k, v in table.items() if CYRILLIC.search(v)]
    if russian:
        print(f"T02: в таблице {name} осталось по-русски: {', '.join(sorted(russian)[:5])}"
              + (f" и ещё {len(russian) - 5}" if len(russian) > 5 else ""))
        rc = 1

    for key, value in table.items():
        original = keys.get(key, "")
        if original.count("\\n") != value.count("\\n"):
            print(f"T03: в {name} у ключа {key} потерян перенос строки")
            rc = 1

sys.exit(rc)
PY
}

if [ "${1:-}" = "--selftest" ]; then
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    ok=0
    cp "$EN" "$TMP/en.backup"

    if check >/dev/null 2>&1; then
        echo "     OK  живые таблицы приняты"
    else
        echo "     .. живые таблицы ещё не полны (перевод в работе)"
    fi

    printf '"probe.russian.left" = "Осталось по-русски";\n' >> "$EN"
    # Вывод ловится в файл, а не трубой: труба уносит с собой и код возврата, и
    # часть строк, и разбирать потом нечего. Этот дом уже платил за трубу.
    check > "$TMP/probe.out" 2>&1 || true
    if grep -q "T02" "$TMP/probe.out"; then
        echo "     OK  русская строка в чужой таблице поймана"
    else
        echo "ПРОВАЛ: русская строка не поймана"; ok=1
    fi
    cp "$TMP/en.backup" "$EN"

    [ $ok -eq 0 ] && echo "SELFTEST OK"
    exit $ok
fi

# T04: таблица обязана читаться. Проверяется ДО остальных правил: на битой
# таблице все прочие проверки говорят о ключах, которых система всё равно не
# увидит.
SINTAKSIS=0
for tablica in "$EN" "$ZH"; do
    if ! plutil -lint "$tablica" >/dev/null 2>&1; then
        echo "T04: таблица не читается системой: $tablica" >&2
        plutil -lint "$tablica" 2>&1 | tail -1 >&2
        SINTAKSIS=1
    fi
done
if [ $SINTAKSIS -ne 0 ]; then
    echo "ВОРОТА ПЕРЕВОДА: битая таблица гасит ВЕСЬ язык, а не одну строку" >&2
    exit 1
fi

if out=$(check); then
    echo "ворота перевода: чисто"
    exit 0
fi
echo "$out" >&2
echo "ВОРОТА ПЕРЕВОДА: интерфейс покажется не на своём языке" >&2
exit 1
