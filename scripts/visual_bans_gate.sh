#!/bin/bash
# Ворота запретов визуала.
#
# Урок пяти отказов ленты, применённый ко ВСЕМУ визуалу: правило, которое
# должно исполняться, живёт в воротах, а не в прозе. `VISUAL_SPEC.md` §6.2
# прямо запретил блок мёртвых строк-хоткеев - и запрет полтора месяца не
# исполнялся, потому что был текстом. Текст читают, соглашаются и делают иначе.
#
# Здесь стоят машиной те запреты спек, которые машина в состоянии проверить.
# Всё, что требует суждения (красиво или нет), остаётся владельцу: ворота
# решают не «нравится», а «нарушено ли названное правило».
set -uo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-Sources}"
fails=0

fail() {
  echo "ОТКАЗ: $1" >&2
  fails=$((fails + 1))
}

# 1. VISUAL_SPEC §6.2: ни одного эмодзи во всём приложении. Эмодзи не
#    тонируются, не совпадают по метрикам с системным шрифтом и являются
#    единственным цветным пятном в монохромном меню.
#    Проверка идёт питоном по КОДОВЫМ ТОЧКАМ, а не грепом по диапазону
#    символов: первая редакция этого гейта покраснела на всех 76 файлах
#    сразу, потому что BSD grep читал диапазон побайтово и ловил кириллицу.
#    Прибор врал раньше кода - ровно тот случай, что уже стоил замера движка.
emoji=$(/usr/bin/python3 - "$SRC" <<'PYEOF'
import pathlib, sys, unicodedata
RANGES = [(0x1F300, 0x1FAFF), (0x1F000, 0x1F0FF), (0x2600, 0x27BF), (0xFE0F, 0xFE0F)]
bad = []
for path in sorted(pathlib.Path(sys.argv[1]).rglob("*.swift")):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for char in line:
            code = ord(char)
            if any(low <= code <= high for low, high in RANGES):
                bad.append(f"{path}:{number}: {char} ({unicodedata.name(char, 'без имени')})")
                break
print("\n".join(bad))
PYEOF
)
[ -n "$emoji" ] && fail "эмодзи в исходниках:
$emoji"

# 2. VISUAL_SPEC §6.2: ручная галочка внутри Text - подделка системного
#    элемента, которую VoiceOver не читает как состояние. Отметку рисует
#    Picker или Toggle.
tick=$(/usr/bin/grep -rn 'Text("✓' "$SRC" 2>/dev/null || true)
[ -n "$tick" ] && fail "ручная галочка в Text: $tick"

# 3. HUD_SPEC §3: в свёрнутой плашке нет текста СОВСЕМ. Проверяется по
#    рисующему файлу - там не должно быть ни одного текстового примитива.
capsule="$SRC/IrizDictate/DictationHUDCapsule.swift"
if [ -f "$capsule" ]; then
  text_prims=$(/usr/bin/grep -nE 'NSTextField|SwiftUI\.Text|NSAttributedString|ProgressView|NSProgressIndicator|Image\(systemName:|VisualEffect' "$capsule" || true)
  [ -n "$text_prims" ] && fail "текстовый примитив в плашке: $text_prims"
fi

# 4. HUD_SPEC, третья правка 11.08.2026: пузырька за живой лентой нет.
#    Пилюля, кант и кольцо ореола убраны и не возвращаются.
if [ -f "$capsule" ]; then
  bubble=$(/usr/bin/grep -nE 'NSVisualEffectView|hasShadow = true' "$capsule" || true)
  [ -n "$bubble" ] && fail "пузырёк вернулся в плашку: $bubble"
fi

# 5. VISUAL_SPEC §6.2: версии в меню нет - первая строка отвечает «что сейчас»,
#    а не «что это». Версия живёт в окне настроек.
menu="$SRC/IrizApp/MenuContentView.swift"
if [ -f "$menu" ]; then
  version=$(/usr/bin/grep -n 'state.version' "$menu" || true)
  [ -n "$version" ] && fail "версия в меню: $version"
fi

# 6. Знак строки меню монохромен: цвета в его геометрии быть не должно
#    (VISUAL_SPEC §5.2 - «цвета в системе нет вообще»).
mark="$SRC/IrizApp/IrizMark.swift"
if [ -f "$mark" ]; then
  colored=$(/usr/bin/grep -nE 'systemRed|systemBlue|systemGreen|systemOrange|systemYellow|systemPurple' "$mark" || true)
  [ -n "$colored" ] && fail "акцентный цвет в знаке строки меню: $colored"
fi

if [ "$fails" -gt 0 ]; then
  echo "visual_bans_gate: нарушено запретов $fails" >&2
  exit 1
fi
echo "visual_bans_gate: OK - шесть запретов спек проверены машиной"
