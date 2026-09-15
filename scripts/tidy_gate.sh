#!/bin/bash
# Ворота уборки: продукт не оставляет мусора ни на диске, ни в настройках.
#
# Повод измеренный, не гипотетический. 06.09.2026 диск владельца встал на нуле
# свободных байт ПОСРЕДИ работы: ни одна команда не могла создать даже файл
# вывода. Разбор нашёл три вида мусора, и каждый копился месяцами молча:
#
#   1,1 ГБ    архив `ggml-large-v3-encoder.mlmodelc.zip` рядом с распакованным
#             каталогом того же имени. После распаковки не нужен никому.
#   2000+     доменов `iriz.tests.insertion.<UUID>` в UserDefaults: каждый прогон
#             тестов вставки заводит suite и не убирает за собой.
#   каталоги  `dictations-quarantine-…` месячной давности.
#
# Слова владельца: «вот мусор весь, который нужно убирать, всегда нужно убирать.
# Это прям надо зашить в правила, причём опять же инструментом».
#
#   scripts/tidy_gate.sh            доклад; красный, если мусор есть
#   scripts/tidy_gate.sh --clean    убрать и доложить
#   scripts/tidy_gate.sh --selftest проверка самих ворот
set -uo pipefail
cd "$(dirname "$0")/.."

SUPPORT="$HOME/Library/Application Support/iriz"
FAIL=0
CLEAN=0
[ "${1:-}" = "--clean" ] && CLEAN=1

# Настройки, которые заводят тесты. Живой домен продукта сюда не подходит по
# построению: у него нет суффикса-UUID.
#
# Считаются ФАЙЛЫ, а не домены. Одного `defaults delete` мало: он забывает домен
# в cfprefsd, а plist остаётся в ~/Library/Preferences, и демон поднимает домен
# обратно из файла. Поймано живьём: после чистки 858 доменов их снова стало 862
# при 2105 файлах на диске.
# Берутся ТОЛЬКО наши домены и только те, в имени которых есть `test`. Чужие
# настройки не трогаются никогда: рядом лежит, например,
# `com.google.chrome.for.testing.plist`, и он не наш.
test_prefs() {
    ls "$HOME/Library/Preferences" 2>/dev/null \
        | grep -E '^(iriz|smltlk|ru\.iriz|ru\.smltlk)' \
        | grep -E 'test' \
        | sed "s|^|$HOME/Library/Preferences/|" || true
}

# Архив, распакованный каталог которого лежит рядом.
unpacked_archives() {
    local dir="$SUPPORT/Models/whisper"
    [ -d "$dir" ] || return 0
    local zip base
    for zip in "$dir"/*.zip; do
        [ -e "$zip" ] || continue
        base="${zip%.zip}"
        [ -d "$base" ] && echo "$zip"
    done
}

stale_quarantines() {
    [ -d "$SUPPORT" ] || return 0
    find "$SUPPORT" -maxdepth 1 -type d -name 'dictations-quarantine-*' -mtime +30 2>/dev/null || true
}

if [ "${1:-}" = "--selftest" ]; then
    # Ворота обязаны краснеть на заведомом мусоре и молчать на чистом доме.
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    ok=0
    mkdir -p "$TMP/Models/whisper/model.mlmodelc"
    : > "$TMP/Models/whisper/model.mlmodelc.zip"
    : > "$TMP/Models/whisper/одинокий.zip"
    found=$(SUPPORT="$TMP"; dir="$TMP/Models/whisper"
        for z in "$dir"/*.zip; do b="${z%.zip}"; [ -d "$b" ] && echo "$z"; done)
    case "$found" in
        *model.mlmodelc.zip) echo "     OK  распакованный архив пойман" ;;
        *) echo "ПРОВАЛ: распакованный архив не пойман"; ok=1 ;;
    esac
    case "$found" in
        *одинокий.zip) echo "ПРОВАЛ: одинокий архив назван мусором — модель потеряли бы"; ok=1 ;;
        *) echo "     OK  одинокий архив не тронут" ;;
    esac
    [ $ok -eq 0 ] && echo "SELFTEST OK"
    exit $ok
fi

echo "=== мусор на диске ==="
ARCHIVES=$(unpacked_archives)
if [ -n "$ARCHIVES" ]; then
    while IFS= read -r zip; do
        echo "  распакованный архив: $zip ($(du -h "$zip" | cut -f1))"
        [ $CLEAN -eq 1 ] && rm -f "$zip" && echo "    удалён"
    done <<< "$ARCHIVES"
    [ $CLEAN -eq 0 ] && FAIL=1
else
    echo "  архивов-дублей нет"
fi

QUARANTINES=$(stale_quarantines)
if [ -n "$QUARANTINES" ]; then
    while IFS= read -r dir; do
        echo "  карантин старше месяца: $dir"
        [ $CLEAN -eq 1 ] && rm -rf "$dir" && echo "    удалён"
    done <<< "$QUARANTINES"
    [ $CLEAN -eq 0 ] && FAIL=1
else
    echo "  карантинов старше месяца нет"
fi

echo
echo "=== мусор в настройках ==="
PREFS=$(test_prefs)
COUNT=$(printf '%s' "$PREFS" | grep -c . || true)
if [ "$COUNT" -gt 0 ]; then
    echo "  настроек от тестов: $COUNT файлов"
    if [ $CLEAN -eq 1 ]; then
        # Файлы сносятся пачкой, а домены забываются одним перезапуском
        # демона. Прежде на каждый файл звался `defaults delete` — 29 684
        # процесса, полчаса работы и никакого выигрыша: cfprefsd всё равно
        # перечитывает каталог целиком.
        printf '%s\n' "$PREFS" | tr '\n' '\0' | xargs -0 rm -f 2>/dev/null
        killall cfprefsd >/dev/null 2>&1
        echo "  удалены"
    else
        FAIL=1
    fi
else
    echo "  настроек от тестов нет"
fi

echo
if [ $FAIL -eq 0 ]; then
    echo "ВОРОТА УБОРКИ: чисто"
else
    echo "ВОРОТА УБОРКИ: мусор есть — убери: bash scripts/tidy_gate.sh --clean" >&2
fi
exit $FAIL
