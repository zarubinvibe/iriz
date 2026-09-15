#!/bin/bash
# Рендер знака smltlk: просмотровые PNG всех состояний в .build/render/,
# пруфы приёмки (16pt/64pt + фазы волны) в .build/proof/,
# AppIcon.icns в .build/ (подхватывает build_app.sh), машинный тест размытием.
# Геометрия — только из Sources/IrizApp/IrizMark.swift, здесь ничего не рисуется.
set -e
cd "$(dirname "$0")/.."
BIN=.build/render-marks
mkdir -p .build/render .build/proof
swiftc -O -o "$BIN" \
  Sources/IrizApp/IrizMark.swift scripts/render-marks/main.swift \
  -framework AppKit -framework CoreGraphics
"$BIN" .build/render .build/AppIcon.iconset .build/proof
# Иконка приложения - отрисованный канонный кадр, а не плоский знак.
#
# Знак строки меню остаётся кодовым и монохромным: у него холст 18 pt и он
# обязан нести раскладку буквой. Требовать от одной формы работать и в 18 pt,
# и в 1024 - испортить обе; разбор того же класса ошибки в VISUAL_SPEC §7.
# Два мастера, а не один. Герой - рендер: мрамор, звёзды, стекло. Ужатый в 32 px
# он теряет смысл: замером гребень горы читался только в 17 колонках из 32, волна
# схлопывалась в полосу. Поэтому мелкие слоты берут отдельный рисованный мастер,
# как это делает Apple - iconset несёт РАЗНОЕ изображение на разных размерах.
CANON_ICON=docs/assets/pantheon/icon-iriz-1024.png
SMALL_ICON=docs/assets/pantheon/icon-iriz-small.png
SMALL_MAX=64
if [ -f "$CANON_ICON" ]; then
    [ -f "$SMALL_ICON" ] || { echo "render_marks: нет мелкого мастера $SMALL_ICON" >&2; exit 1; }
    rm -rf .build/AppIcon.iconset
    mkdir -p .build/AppIcon.iconset
    for pair in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
                "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
                "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
        set -- $pair
        if [ "$1" -le "$SMALL_MAX" ]; then src=$SMALL_ICON; else src=$CANON_ICON; fi
        sips -z "$1" "$1" "$src" --out ".build/AppIcon.iconset/$2.png" >/dev/null
    done
    echo "icon: герой $CANON_ICON, мелкие слоты до ${SMALL_MAX}px - $SMALL_ICON"
fi
iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
echo "icon: .build/AppIcon.icns"
