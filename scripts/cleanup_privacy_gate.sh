#!/bin/bash
# Ворота приватности очистки речи.
#
# Обещание владельцу: обычная диктовка наружу не уходит никогда. Наружу ходит
# ровно один режим, который он включает руками и рядом с которым стоит
# предупреждение.
#
# Обещание держится не комментарием. Здесь проверяется три вещи, каждая ловит
# свой способ его нарушить:
#
#   C01  слова внешнего запроса зовутся ровно из одного места в продукте.
#        Второй вызов - это второй путь наружу, и он появится не по злому
#        умыслу, а потому что «тут тоже нужно почистить».
#   C02  единственный вызов стоит за проверкой режима, и проверка эта первой
#        строкой. Проверка ниже по телу означает, что до неё что-то успело
#        произойти.
#   C03  умолчание режима не отправляет текст наружу.
#
# Использование:
#   scripts/cleanup_privacy_gate.sh
#   scripts/cleanup_privacy_gate.sh --selftest
set -uo pipefail
cd "$(dirname "$0")/.."

CONTROLLER=Sources/IrizDictate/DictationController.swift
MODE=Sources/IrizDictate/SpeechCleanup.swift
SETTINGS=Sources/IrizDictate/DictationSettings.swift

check() {
    local rc=0

    local callers
    callers=$(grep -rln "SpeechCleanupRequest.body" Sources/ | grep -v "SpeechCleanupRequest.swift" | wc -l | tr -d ' ')
    if [ "$callers" != "1" ]; then
        echo "C01: внешний запрос зовётся из $callers мест вместо одного"
        rc=1
    fi

    # Тело `cleanedExternally` обязано начинаться проверкой режима.
    local guard
    guard=$(grep -A2 "private func cleanedExternally" "$CONTROLLER" | grep -c "speechCleanupMode == .external")
    if [ "$guard" != "1" ]; then
        echo "C02: вызов наружу не закрыт проверкой режима первой строкой"
        rc=1
    fi

    grep -q "return .local" "$SETTINGS" || {
        echo "C03: умолчание режима не найдено - оно обязано быть местным"
        rc=1
    }
    grep -q "self == .external" "$MODE" || {
        echo "C03: признак отправки наружу не привязан к единственному режиму"
        rc=1
    }
    return $rc
}

if [ "${1:-}" = "--selftest" ]; then
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    ok=0
    check > /dev/null || { echo "ПРОВАЛ: живое дерево не проходит ворота"; ok=1; }
    echo "     OK  живое дерево принято"

    # Подделка: второй путь наружу.
    cp "$CONTROLLER" "$TMP/backup"
    printf '\n// let sneak = SpeechCleanupRequest.body(text: "x")\n' >> Sources/IrizDictate/SpeechCleanup.swift
    if check > /dev/null; then
        echo "ПРОВАЛ: второй путь наружу не пойман"; ok=1
    else
        echo "     OK  второй путь наружу отвергнут"
    fi
    git checkout -- Sources/IrizDictate/SpeechCleanup.swift 2>/dev/null

    [ $ok -eq 0 ] && echo "SELFTEST OK"
    exit $ok
fi

if out=$(check); then
    echo "ворота приватности очистки: чисто"
    exit 0
fi
echo "$out" >&2
echo "ВОРОТА ПРИВАТНОСТИ ОЧИСТКИ: обещание нарушено" >&2
exit 1
