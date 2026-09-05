#!/bin/bash
# Враждебная проба ворот запретов визуала.
#
# Улика не «ворота зелёные на нашем дереве», а «ворота краснеют на каждом
# нарушении по отдельности». Поэтому проба строит СЛОМАННЫЕ копии исходников
# и проверяет, что гейт ловит именно то нарушение, ради которого он написан.
set -uo pipefail
cd "$(dirname "$0")/.."

gate="$PWD/scripts/visual_bans_gate.sh"
tmp=$(/usr/bin/mktemp -d)
trap 'rm -rf "$tmp"' EXIT

plant() {   # plant -> каталог с честной копией разметки исходников
  local dir="$tmp/case-$RANDOM$RANDOM"
  mkdir -p "$dir/IrizApp" "$dir/IrizDictate"
  printf 'import SwiftUI\nstruct MenuContentView: View { var body: some View { Text("Настройки") } }\n' \
    > "$dir/IrizApp/MenuContentView.swift"
  printf 'import AppKit\nfinal class DictationHUDCapsuleView: NSView { func draw() {} }\n' \
    > "$dir/IrizDictate/DictationHUDCapsule.swift"
  printf 'import AppKit\nenum IrizMark { static let width = 18.0 }\n' \
    > "$dir/IrizApp/IrizMark.swift"
  echo "$dir"
}

expect_green() {
  if ! bash "$gate" "$1" >/dev/null 2>&1; then
    echo "FAIL: ворота покраснели на честной копии ($2)"; exit 1
  fi
}
expect_red() {
  if bash "$gate" "$1" >/dev/null 2>&1; then
    echo "FAIL: ворота пропустили $2"; exit 1
  fi
}

# 0. Честная копия - зелёная. Без этого любая краснота ниже ничего не доказывает.
dir="$(plant)"; expect_green "$dir" "нетронутая разметка"

# 1. Эмодзи.
dir="$(plant)"; printf 'let badge = "🔴 запись"\n' >> "$dir/IrizApp/MenuContentView.swift"
expect_red "$dir" "эмодзи в исходниках"

# 2. Ручная галочка внутри Text.
dir="$(plant)"; printf 'let tick = Text("✓ Русская")\n' >> "$dir/IrizApp/MenuContentView.swift"
expect_red "$dir" "ручную галочку в Text"

# 3. Текстовый примитив в плашке.
dir="$(plant)"; printf 'let label = NSTextField(labelWithString: "запись")\n' >> "$dir/IrizDictate/DictationHUDCapsule.swift"
expect_red "$dir" "текстовый примитив в плашке"

# 4. Возврат пузырька.
dir="$(plant)"; printf 'let blur = NSVisualEffectView()\n' >> "$dir/IrizDictate/DictationHUDCapsule.swift"
expect_red "$dir" "возврат пузырька"

# 5. Версия в меню.
dir="$(plant)"; printf 'let v = Text(state.version)\n' >> "$dir/IrizApp/MenuContentView.swift"
expect_red "$dir" "версию в меню"

# 6. Цвет в монохромном знаке.
dir="$(plant)"; printf 'let tint = NSColor.systemRed\n' >> "$dir/IrizApp/IrizMark.swift"
expect_red "$dir" "акцентный цвет в знаке строки меню"

echo "OK: ворота запретов визуала краснеют на всех шести нарушениях по отдельности"
