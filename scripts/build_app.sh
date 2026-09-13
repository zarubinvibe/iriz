#!/bin/bash
# Сборка и установка /Applications/iriz.app: swift build (только arm64),
# бандл, подпись smltlk-selfsign, установка по фиксированному пути.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(tr -d '\n' < RELEASE_VERSION)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build_app: неверная RELEASE_VERSION" >&2; exit 1; }
fail() { printf 'build_app: %s\n' "$*" >&2; exit 1; }
check_meeting_resources() {
    local bundle="$1/Contents/Resources/IrizApp_IrizDictate.bundle"
    local package="$bundle/MeetingMinutes" links file digest
    [ -d "$package" ] || fail "пакет протокола MeetingMinutes не найден в $bundle"
    links=$(find "$bundle" -type l -print) || fail "пакет протокола не удалось проверить"
    [ -z "$links" ] || fail "симлинк в пакете протокола: $links"
    for file in template.docx fields.json data.schema.json manifest.json README.md template.md \
        docs/formatting.md docs/filling-rules.md docs/filler-usage.md docs/owner-changes.md docs/verification.md \
        scripts/fill_template.py scripts/verify_package.py tests/test_fill_template.py \
        examples/data.example.json examples/filled.example.docx \
        fonts/PT_Serif-Web-Regular.ttf fonts/PT_Serif-Web-Bold.ttf fonts/OFL.txt; do
        [ -f "$package/$file" ] && [ -s "$package/$file" ] || fail "пакет протокола: отсутствует или пуст $file"
    done
    digest=$(shasum -a 256 "$package/template.docx") || fail "SHA-256 шаблона протокола не удалось прочитать"
    [ "${digest%% *}" = 8b4ffde7a7d09c6f3450b2de8667334fe79f544157553c3e81d77456b43807ff ] \
        || fail "SHA-256 шаблона протокола не совпадает с эталоном"
}
swift build -c release --arch arm64
# Иконка: тот же IrizMark.iconImage → iconset → .build/AppIcon.icns (render_marks.sh).
bash scripts/render_marks.sh
INSTALL_DIR=/Applications
BACKUP_PARENT="$HOME/Library/Application Support"
INSTALL_APP="$INSTALL_DIR/iriz.app"
OLD_APP="$INSTALL_DIR/smltlk.app"
STAGE_ROOT=$(mktemp -d "$PWD/.build/install-app.XXXXXX")
APP="$STAGE_ROOT/iriz.app"
BACKUP_DIR=""
INSTALLING=0
NEW_INSTALL_STARTED=0
finish() {
  local result=$?
  trap - EXIT
  if [ "$INSTALLING" -eq 1 ]; then
    # Не удаляем даже неполную новую копию: при ошибке она остаётся рядом с backup.
    if [ "$NEW_INSTALL_STARTED" -eq 1 ] && { [ -e "$INSTALL_APP" ] || [ -L "$INSTALL_APP" ]; }; then
      mv "$INSTALL_APP" "$BACKUP_DIR/failed-iriz.app" \
        || { printf 'build_app: откат требует помощи; резервный каталог: %s\n' "$BACKUP_DIR" >&2; exit 1; }
    fi
    if { [ -e "$BACKUP_DIR/iriz.app" ] || [ -L "$BACKUP_DIR/iriz.app" ]; } \
        && [ ! -e "$INSTALL_APP" ] && [ ! -L "$INSTALL_APP" ]; then
      mv "$BACKUP_DIR/iriz.app" "$INSTALL_APP" \
        || { printf 'build_app: не удалось вернуть прежнее приложение из %s\n' "$BACKUP_DIR" >&2; exit 1; }
    fi
    printf 'build_app: замена отменена, файловое состояние до замены восстановлено\n' >&2
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    rmdir "$STAGE_ROOT" 2>/dev/null || true
  else
    printf 'build_app: рабочий каталог: %s\n' "$STAGE_ROOT" >&2
  fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/IrizApp "$APP/Contents/MacOS/iriz"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ресурсные бандлы SwiftPM. Сборщик копирует ТОЛЬКО исполняемый файл, а таблицы
# перевода и картинки живут в `*_*.bundle` рядом с ним в `.build`. Без этой
# строки `Bundle.module` в приложении не находит ничего, и продукт молча
# показывает русский на любом выбранном языке: английский и китайский падают в
# оригинал, потому что `L()` возвращает исходную строку, когда таблицы нет.
# Поймано кадром 06.09.2026: `settings-zh.png` вышел целиком по-русски.
# Берём бандлы рядом с бинарём; кавычки сохраняют пробелы в именах.
[ -d .build/release/IrizApp_IrizCore.bundle ] || fail "ресурсный бандл IrizApp_IrizCore.bundle не найден"
for bundle in .build/release/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
# Комплект — обычный ресурс приложения; вложенные Python-скрипты не исполняются.
check_meeting_resources "$APP"

# Движок кандидата приходит бинарным фреймворком SwiftPM (whisper.cpp собран
# заранее, исходников у него в пакете нет). В бандл он сам не попадает: сборщик
# копирует только исполняемый файл. Без этой строки приложение падало на старте
# с «Library not loaded: @rpath/whisper.framework» - тесты и CLI при этом работали,
# потому что бегут прямо из .build, где фреймворк лежит рядом. Поймано живьём
# 03.09.2026, ПОСЛЕ того как всё остальное было зелёным.
WHISPER_FRAMEWORK=.build/release/whisper.framework
if [ ! -d "$WHISPER_FRAMEWORK" ]; then
    echo "build_app: whisper.framework не найден в .build - движок диктовки не запустится" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$WHISPER_FRAMEWORK" "$APP/Contents/Frameworks/"
if ! otool -l "$APP/Contents/MacOS/iriz" | awk '$1 == "path" && $2 == "@executable_path/../Frameworks" { found=1 } END { exit !found }'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/iriz" \
        || fail "не удалось добавить rpath фреймворков"
fi
otool -l "$APP/Contents/MacOS/iriz" | awk '$1 == "path" && $2 == "@executable_path/../Frameworks" { found=1 } END { exit !found }' \
    || fail "rpath фреймворков отсутствует"
# Фреймворк приходит подписанным вендором, и dyld отказывается его грузить в наш
# процесс: «different Team IDs». --deep на приложении чужую подпись не перебивает,
# поэтому фреймворк подписывается ОТДЕЛЬНО и до подписи бандла.
codesign --force --sign "smltlk-selfsign" --options runtime \
    "$APP/Contents/Frameworks/whisper.framework" || fail "подпись фреймворка не прошла"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>iriz</string>
<key>CFBundleIdentifier</key><string>ru.iriz.app</string>
<key>CFBundleName</key><string>iriz</string>
<key>CFBundleDisplayName</key><string>iriz</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Микрофон нужен, чтобы превращать твою речь в текст.</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign "smltlk-selfsign" --options runtime --entitlements entitlements.plist "$APP" \
    || fail "подпись приложения не прошла"
codesign --verify --deep --strict "$APP" || fail "проверка подготовленной подписи не прошла"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority|Identifier'

# До этой точки установленное приложение и его процессы не менялись.
mkdir -p "$BACKUP_PARENT"
BACKUP_DIR=$(mktemp -d "$BACKUP_PARENT/iriz-app-backup.XXXXXX")
for process in iriz smltlk; do
    if pgrep -x "$process" >/dev/null; then
        pkill -x "$process" || { rc=$?; [ "$rc" -eq 1 ] || fail "не удалось остановить $process"; }
    else
        rc=$?
        [ "$rc" -eq 1 ] || fail "pgrep завершился с кодом $rc"
    fi
done
sleep 1
for process in iriz smltlk; do
    if pgrep -x "$process" >/dev/null; then
        fail "не удалось остановить $process; установка отменена"
    else
        rc=$?
        [ "$rc" -eq 1 ] || fail "pgrep завершился с кодом $rc"
    fi
done
INSTALLING=1
if [ -e "$INSTALL_APP" ] || [ -L "$INSTALL_APP" ]; then
    mv "$INSTALL_APP" "$BACKUP_DIR/iriz.app" || fail "не удалось сохранить прежнее приложение"
fi
NEW_INSTALL_STARTED=1
mv "$APP" "$INSTALL_APP" || fail "не удалось установить подготовленное приложение"
codesign --verify --deep --strict "$INSTALL_APP" || fail "проверка установленной подписи не прошла"
check_meeting_resources "$INSTALL_APP"
INSTALLING=0
printf 'build_app: установлено %s; резервный каталог: %s\n' "$VERSION" "$BACKUP_DIR"

# Старое имя тоже сохраняется, а не удаляется безвозвратно.
if [ -e "$OLD_APP" ] || [ -L "$OLD_APP" ]; then
    mv "$OLD_APP" "$BACKUP_DIR/smltlk.app" \
        || printf 'build_app: не удалось перенести старый %s; он оставлен на месте\n' "$OLD_APP" >&2
fi
