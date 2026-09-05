#!/usr/bin/env bash
# Граница модулей: `IrizCore` остаётся ядром без интерфейса.
#
# Команда предписана советом дословно (`02_council/VERDICT_FINAL.md:260-261`)
# как обязательная — и полтора месяца не исполнялась ничем. Граница держалась
# честностью автора, а это не проверка.
#
# Цена нарушения конкретна: тесты `IrizCoreTests` гоняются без графической
# сессии и без разрешений. Один случайный `import AppKit` в новом файле ядра —
# и они начнут требовать WindowServer, Универсальный доступ и живой экран,
# то есть просто перестанут гоняться в чистой среде.
#
# `Dict.swift` — единственное разрешённое исключение: орфографический гейт
# опирается на `NSSpellChecker`, другого системного словаря в macOS нет,
# а на нём стоит решение `LayoutDetector`. Исключение именное, не по маске:
# новый файл с AppKit гейт уронит.
#
# Коды: 0 — граница цела, 1 — нарушена.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

CORE="Sources/IrizCore"
FORBIDDEN='CGEvent|AXUIElement|NSApplication|NSWindow|NSStatusItem|SMAppService|ServiceManagement|SwiftUI|URLSession'
ALLOWED_APPKIT_FILE="$CORE/Dict.swift"

status=0

HITS="$(grep -rlE "$FORBIDDEN" "$CORE" 2>/dev/null || true)"
if [ -n "$HITS" ]; then
    echo "module_boundary_gate: ОТКАЗ — интерфейсные символы в ядре:" >&2
    printf '%s\n' "$HITS" | sed 's/^/  /' >&2
    status=1
fi

APPKIT="$(grep -rl 'import AppKit' "$CORE" 2>/dev/null | sort || true)"
if [ "$APPKIT" != "$ALLOWED_APPKIT_FILE" ] && [ -n "$APPKIT" ]; then
    echo "module_boundary_gate: ОТКАЗ — AppKit в ядре вне единственного исключения:" >&2
    printf '%s\n' "$APPKIT" | sed 's/^/  /' >&2
    echo "  разрешено только: $ALLOWED_APPKIT_FILE (NSSpellChecker)" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    FILES="$(find "$CORE" -name '*.swift' | wc -l | tr -d ' ')"
    echo "module_boundary_gate: граница цела — $FILES файлов ядра, AppKit только в $(basename "$ALLOWED_APPKIT_FILE")"
fi

exit "$status"
