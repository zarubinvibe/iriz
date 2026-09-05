#!/bin/bash
# Сборка и установка /Applications/iriz.app: swift build (только arm64),
# бандл, подпись smltlk-selfsign, установка по фиксированному пути.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
# Иконка: тот же IrizMark.iconImage → iconset → .build/AppIcon.icns (render_marks.sh).
bash scripts/render_marks.sh
APP=/Applications/iriz.app
OLD_APP=/Applications/smltlk.app
# Запущенное приложение держит свой бандл: rm -rf по нему может не пройти, и скрипт
# МОЛЧА оставит старую сборку — «поставил и не работает» с правильным кодом в репозитории.
# Поэтому сначала гасим процесс, потом сверяем, что бандла действительно нет.
if pgrep -x iriz || pgrep -x smltlk; then
  pkill -x iriz 2>/dev/null || true
  pkill -x smltlk 2>/dev/null || true
else
  rc=$?
  [ "$rc" -eq 1 ] || { echo "build_app: pgrep завершился с кодом $rc"; exit "$rc"; }
fi
sleep 1
if pgrep -x iriz || pgrep -x smltlk; then
  echo "build_app: не удалось остановить приложение — установка отменена"
  exit 1
fi
rm -rf "$APP"
[ -e "$APP" ] && { echo "build_app: не удалось удалить $APP — установка отменена"; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/IrizApp "$APP/Contents/MacOS/iriz"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Движок кандидата приходит бинарным фреймворком SwiftPM (whisper.cpp собран
# заранее, исходников у него в пакете нет). В бандл он сам не попадает: сборщик
# копирует только исполняемый файл. Без этой строки приложение падало на старте
# с «Library not loaded: @rpath/whisper.framework» - тесты и CLI при этом работали,
# потому что бегут прямо из .build, где фреймворк лежит рядом. Поймано живьём
# 03.09.2026, ПОСЛЕ того как всё остальное было зелёным.
WHISPER_FRAMEWORK="$(find .build -maxdepth 3 -type d -name whisper.framework -path '*release*' | head -1)"
if [ -z "$WHISPER_FRAMEWORK" ]; then
    echo "build_app: whisper.framework не найден в .build - движок диктовки не запустится" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/whisper.framework"
cp -R "$WHISPER_FRAMEWORK" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/iriz" 2>/dev/null || true
# Фреймворк приходит подписанным вендором, и dyld отказывается его грузить в наш
# процесс: «different Team IDs». --deep на приложении чужую подпись не перебивает,
# поэтому фреймворк подписывается ОТДЕЛЬНО и до подписи бандла.
codesign --force --sign "smltlk-selfsign" --options runtime \
    "$APP/Contents/Frameworks/whisper.framework"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>iriz</string>
<key>CFBundleIdentifier</key><string>ru.iriz.app</string>
<key>CFBundleName</key><string>iriz</string>
<key>CFBundleDisplayName</key><string>iriz</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Микрофон нужен, чтобы превращать вашу речь в текст.</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign "smltlk-selfsign" --options runtime --entitlements entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority|Identifier'
# Установленный бинарь обязан быть НОВЕЕ собранного источника — иначе установка не состоялась.
if [ "$APP/Contents/MacOS/iriz" -ot .build/release/IrizApp ]; then
  echo "build_app: в /Applications лежит старый бинарь — установка не состоялась"; exit 1
fi
echo "build_app: установлено $(date -r "$APP/Contents/MacOS/iriz" '+%H:%M:%S')"

# Старый бандл убирается ПОСЛЕ успешной установки нового: иначе неудачная
# сборка оставила бы владельца вообще без приложения.
if [ -d "$OLD_APP" ] && [ -x "$APP/Contents/MacOS/iriz" ]; then
    rm -rf "$OLD_APP"
    echo "build_app: старый $OLD_APP удалён"
fi
