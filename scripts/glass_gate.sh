#!/bin/bash
# Ворота закреплённого вида окна настроек.
#
# Владелец принял окно словами «сохраняй, чтобы в следующие разы было ровно так
# же». Текстом такое не держится: следующий круг прочитает описание, согласится
# и всё равно сделает иначе. Держит только проверка, которая краснеет.
#
# Два уровня, и оба нужны:
#
#   РЕЦЕПТ    статикой по исходнику. Ловит подмену устройства до сборки:
#             матовый материал вместо стекла, `.regular` на плите, `.opacity`
#             на стекле (он молча схлопывает преломление).
#   ЗАМЕР     живым окном. Ловит то, чего в исходнике не видно: система
#             поменяла поведение материала, плита сравнялась с фоном, стекло
#             перестало преломлять.
#
# Использование:
#   scripts/glass_gate.sh              полная проверка (нужен собранный .app)
#   scripts/glass_gate.sh --static     только рецепт, без окна на экране
#   scripts/glass_gate.sh --selftest   проверка самих ворот
set -uo pipefail
cd "$(dirname "$0")/.."

GLASS=Sources/IrizCore/IrizGlass.swift
FAIL=0

say_fail() { echo "ВОРОТА СТЕКЛА: $1" >&2; FAIL=1; }

check_recipe() {
    local file=$1
    local rc=0

    # Фон окна - прозрачное стекло. Владелец выбрал именно `.clear`: `.regular`
    # правит светимость подложки и потому плотный.
    grep -q 'glassEffect(.clear, in: .rect(cornerRadius: 0))' "$file" \
        || { echo "R01: фон окна больше не прозрачное стекло"; rc=1; }

    # Плита - то же стекло плюс ЗАЛИВКА ПОД НИМ. Именно заливка даёт толщу:
    # замер 05.09.2026 показал, что тон стекла на пропускание не влияет
    # (подъём с 0.20 до 0.42 сдвинул 0.418 на 0.420). Без заливки плита
    # сливается с фоном и текст на ней не читается на светлом.
    grep -qE 'Color\.(white|black)\.opacity' "$file" \
        || { echo "R02: плита потеряла заливку и сольётся с фоном"; rc=1; }

    # `.opacity` на стекле схлопывает преломление молча - правило G04 линтера
    # скилла liquid-glass. Проверяется ЦЕПОЧКА МОДИФИКАТОРОВ, а не соседняя
    # строка: заливка-сосед с альфой цвета законна и стоит рядом в каждой
    # плите. Первая версия правила ловила именно её и краснела на здоровом
    # дереве.
    if python3 - "$file" <<'PYGATE'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
hit = False
for i, line in enumerate(lines):
    if ".glassEffect(" not in line:
        continue
    if ".opacity(" in line:
        hit = True
        break
    # Цепочка: следующие строки, начинающиеся с точки, принадлежат тому же виду.
    for follow in lines[i + 1:]:
        stripped = follow.strip()
        if not stripped.startswith("."):
            break
        if stripped.startswith(".opacity("):
            hit = True
            break
    if hit:
        break
sys.exit(0 if hit else 1)
PYGATE
    then
        echo "R03: .opacity в цепочке со стеклом - преломление схлопнется"
        rc=1
    fi

    # Системный `.secondary` на стекле не читается: разбор намерил 2.84 у
    # строки состояния и 3.32 у мелкой сноски при пороге WCAG 4.5. Он
    # рассчитан на непрозрачную подложку, а сквозь плиту видно что угодно.
    if grep -q 'foregroundStyle(.secondary)' Sources/IrizSettings/IrizSettingsView.swift Sources/IrizCore/IrizLook.swift 2>/dev/null; then
        echo "R05: системный .secondary на стекле - контраст ниже порога"
        rc=1
    fi

    # Матовый материал допустим ТОЛЬКО как откат для систем до macOS 26.
    if grep -q 'NSVisualEffectView' "$file" && ! grep -q 'macOS 26.0' "$file"; then
        echo "R04: матовый материал без отката по версии - это не Liquid Glass"
        rc=1
    fi
    return $rc
}

if [ "${1:-}" = "--selftest" ]; then
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    ok=0
    cp "$GLASS" "$TMP/good.swift"
    check_recipe "$TMP/good.swift" >/dev/null || { echo "ПРОВАЛ: живой файл не проходит рецепт"; ok=1; }
    echo "     OK  рецепт: живой файл принят"

    sed 's/glassEffect(.clear, in: .rect(cornerRadius: 0))/glassEffect(.regular, in: .rect(cornerRadius: 0))/' \
        "$GLASS" > "$TMP/dense.swift"
    if check_recipe "$TMP/dense.swift" >/dev/null; then
        echo "ПРОВАЛ: плотный фон не пойман"; ok=1
    else
        echo "     OK  рецепт: плотный фон отвергнут"
    fi

    # Подделка: прозрачность вешается ЦЕПОЧКОЙ на само стекло.
    sed 's|\.glassEffect(\.clear, in: \.rect(cornerRadius: 0))|.glassEffect(.clear, in: .rect(cornerRadius: 0))\n                .opacity(0.8)|' "$GLASS" > "$TMP/chain.swift"
    if check_recipe "$TMP/chain.swift" >/dev/null; then
        echo "ПРОВАЛ: прозрачность на стекле не поймана"; ok=1
    else
        echo "     OK  прозрачность в цепочке со стеклом отвергнута"
    fi

    sed -E 's/Color\.(white|black)\.opacity/Color.plain/' "$GLASS" > "$TMP/nofill.swift"
    if check_recipe "$TMP/nofill.swift" >/dev/null; then
        echo "ПРОВАЛ: плита без заливки не поймана"; ok=1
    else
        echo "     OK  рецепт: плита без заливки отвергнута"
    fi

    python3 scripts/glass_probe.py --selftest || ok=1
    [ $ok -eq 0 ] && echo "SELFTEST OK"
    exit $ok
fi

echo "=== рецепт ==="
if out=$(check_recipe "$GLASS"); then
    echo "рецепт цел"
else
    echo "$out"
    say_fail "исходник разошёлся с принятым видом"
fi

[ "${1:-}" = "--static" ] && exit $FAIL

APP=/Applications/iriz.app/Contents/MacOS/iriz
if [ ! -x "$APP" ]; then
    echo "ВОРОТА СТЕКЛА: нет собранного приложения, замер невозможен" >&2
    echo "собери: bash scripts/build_app.sh" >&2
    exit 2
fi

echo
echo "=== замер живого окна ==="
SHOTS=$(mktemp -d); trap 'rm -rf "$SHOTS"' EXIT
if ! "$APP" --glass-probe "$SHOTS" >/dev/null 2>&1; then
    say_fail "проба не сняла кадры"
    exit $FAIL
fi
python3 scripts/glass_probe.py --shots "$SHOTS" --appearance light --locked || FAIL=1
exit $FAIL
