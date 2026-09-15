#!/bin/bash
# Гейт этапа 7 (негативы): прогон `smltlk fix` по Tests/fixtures/negative.txt.
# Требуется РОВНО ноль изменений; каждое расхождение печатается со строкой.
# Коды: 0 — чисто, 1 — есть изменения, 2 — сборка/запуск сломаны.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

# Гейт tracked-data живёт только в приватном дереве: он перечисляет спрятанные
# каталоги поимённо, и в публичном репозитории такой список — не защита, а
# подсказка, что искать. Здесь он вызывается, если есть, и не притворяется
# выполненным, если его нет.
if [ -f scripts/privacy_tracked_data_gate.sh ]; then
    bash scripts/privacy_tracked_data_gate.sh || exit 1
else
    echo "negative_check: tracked-data гейт отсутствует (приватная оснастка) — пропущен"
fi

python3 <<'PY' || exit 1
from pathlib import Path
import re

needles = re.compile(r'URLSession|URLRequest|http://|https://|NWConnection|CFNetwork')
found = []

for path in sorted(Path("Sources").rglob("*.swift")):
    text = path.read_text()
    code = []
    i = 0
    block_depth = 0
    in_string = False
    escaped = False
    while i < len(text):
        if block_depth:
            if text.startswith("/*", i):
                block_depth += 1
                i += 2
            elif text.startswith("*/", i):
                block_depth -= 1
                i += 2
            else:
                code.append("\n" if text[i] == "\n" else " ")
                i += 1
        elif in_string:
            code.append(text[i])
            if escaped:
                escaped = False
            elif text[i] == "\\":
                escaped = True
            elif text[i] == '"':
                in_string = False
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end == -1 else end
        elif text.startswith("/*", i):
            block_depth = 1
            i += 2
        else:
            code.append(text[i])
            if text[i] == '"':
                in_string = True
            i += 1

    for line_number, line in enumerate("".join(code).splitlines(), 1):
        for match in needles.finditer(line):
            found.append(f"{path}:{line_number}: {match.group()}")

if found:
    print("negative_check: найдены сетевые вызовы:")
    print("\n".join(found))
    raise SystemExit(1)
print("negative_check: сетевых вызовов нет")
PY

swift build -c release || { echo "negative_check: сборка упала"; exit 2; }
BIN=.build/release/smltlk
FIXTURE=Tests/fixtures/negative.txt

total=0
changed=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|'#'*) continue ;;
    esac
    total=$((total + 1))
    out=$(printf '%s' "$line" | "$BIN" fix)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'ОШИБКА rc=%d: %s\n' "$rc" "$line"
        changed=$((changed + 1))
    elif [ "$out" != "$line" ]; then
        printf 'ИЗМЕНЕНО: [%s] -> [%s]\n' "$line" "$out"
        changed=$((changed + 1))
    fi
done < "$FIXTURE"

printf 'negative_check: %d строк, %d изменений\n' "$total" "$changed"
[ "$changed" -eq 0 ]
