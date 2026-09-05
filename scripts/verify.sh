#!/bin/bash
# Проверка перед коммитом: тесты и ворота стекла, с ЧЕСТНЫМ кодом возврата.
#
# Зачем отдельный скрипт на две команды: 05.09.2026 красные тесты уехали в
# коммит, потому что в цепочке `swift test 2>&1 | tail -2 && git commit` код
# возврата берётся у `tail`, а не у теста. Труба глотает провал молча.
# Здесь код возврата берётся у самой команды, а вывод всё равно режется.
#
# Набор «Codex CLI runner» гоняет реальные процессы с таймаутами и под
# нагрузкой (параллельная сборка бандла, съёмка пробы) даёт плавающие падения.
# Поэтому тесты идут ПЕРВЫМИ и в одиночку, до всего тяжёлого.
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0

echo "=== тесты ==="
if swift test > /tmp/iriz-verify-tests.log 2>&1; then
    tail -1 /tmp/iriz-verify-tests.log
else
    echo "ТЕСТЫ КРАСНЫЕ:"
    grep -E "✘|error:" /tmp/iriz-verify-tests.log | head -20
    FAIL=1
fi

echo
echo "=== ворота приватности очистки ==="
bash scripts/cleanup_privacy_gate.sh || FAIL=1

echo
echo "=== ворота хранения встречи ==="
bash scripts/meeting_storage_gate.sh || FAIL=1

echo
echo "=== ворота перевода ==="
bash scripts/translation_gate.sh || FAIL=1

echo
echo "=== ворота стекла (рецепт) ==="
bash scripts/glass_gate.sh --static || FAIL=1

if [ "${1:-}" = "--full" ]; then
    echo
    echo "=== ворота стекла (живой замер) ==="
    bash scripts/glass_gate.sh || FAIL=1
fi

echo
[ $FAIL -eq 0 ] && echo "ПРОВЕРКА ЗЕЛЁНАЯ" || echo "ПРОВЕРКА КРАСНАЯ"
exit $FAIL
