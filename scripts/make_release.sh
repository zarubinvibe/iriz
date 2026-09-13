#!/bin/bash
# Сборка релиза iriz в release/dist/ —
#   iriz-<version>-arm64.dmg      (Apple Silicon)
#   universal — только с IRIZ_RELEASE_VARIANTS='arm64 universal'; это проверка
#   архитектур пакета, а не обещание проверенного на Intel распознавания.
#   IRIZ_DMG_HEADLESS=1 — образ без Finder/фона для CI; по умолчанию при CI=true.
#   SMLTLK_SIGN_IDENTITY=- — ad-hoc подпись для проверки сборки на чужой машине.
#
# Отличия от scripts/build_app.sh (тот — установка разработчика в /Applications):
#   • собирает в отдельный scratch-path, чтобы не драться за лок SwiftPM с .build;
#   • universal включается отдельно; lipo подтверждает архитектуры, но живого
#     Intel-мака для проверки распознавания здесь нет;
#   • кладёт в образ ТОЛЬКО приложение и ссылку на Applications: установка -
#     перетаскивание, как у любой программы Apple. Модель распознавания
#     приезжает потом, из самого приложения (шаг знакомства «Скачаем
#     распознавание»): возить в выпуске слепок модели значит раздать всем
#     прошлогоднюю версию и полгигабайта сверху;
#   • ничего не ставит в систему; нотаризация только с notary-профилем.
#
# Нотаризация включается переменной IRIZ_NOTARY_PROFILE - именем профиля
# учётки notarytool в связке ключей. Заводится один раз:
#
#   xcrun notarytool store-credentials iriz-notary \
#     --apple-id <почта Apple ID> --team-id <TEAMID> --password <пароль-приложения>
#
# С профилем выпуск подписывается настоящим Developer ID, уходит на проверку в
# Apple, получает билет на приложение и на образ; Gatekeeper проверяется
# на машине сборки. Без профиля нотаризации нет, запуск у получателя не обещан.
#
# Переменные окружения:
#   SMLTLK_VERSION         — версия (по умолчанию первая строка RELEASE_VERSION)
#   IRIZ_BUNDLE_VERSION    — CFBundleVersion (по умолчанию та же версия)
#   SMLTLK_SIGN_IDENTITY   — имя сертификата (по умолчанию smltlk-selfsign)
#   IRIZ_NOTARY_PROFILE    — профиль notarytool; пусто = без нотаризации
#   SMLTLK_SCRATCH         — каталог сборки (по умолчанию release/build)
#   IRIZ_RELEASE_DIST      — каталог результата (по умолчанию release/dist)
#   IRIZ_RELEASE_VARIANTS  — arm64 или 'arm64 universal'
#   IRIZ_DMG_HEADLESS      — 1/0; без Finder или с оформлением (по умолчанию CI)
#   SMLTLK_DMG_FORMAT      — формат hdiutil (по умолчанию ULFO, lzfse)
#
# Коды возврата: 0 — выбранные образы собраны; 1 — проверка не прошла.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"

BUNDLE_ID="ru.iriz.app"
IDENTITY="${SMLTLK_SIGN_IDENTITY:-smltlk-selfsign}"
SCRATCH="${SMLTLK_SCRATCH:-$ROOT/release/build}"
DIST="${IRIZ_RELEASE_DIST:-$ROOT/release/dist}"
DMG_FORMAT="${SMLTLK_DMG_FORMAT:-ULFO}"
VARIANTS="${IRIZ_RELEASE_VARIANTS:-arm64}"
HEADLESS="${IRIZ_DMG_HEADLESS:-${CI:-0}}"
# Пустой профиль отключает нотаризацию. Developer ID всё равно использует
# сервер меток времени Apple; ad-hoc и локальная самоподпись обходятся без него.
NOTARY_PROFILE="${IRIZ_NOTARY_PROFILE:-}"
fail() { printf 'make_release: %s\n' "$*" >&2; exit 1; }
if [ -n "$NOTARY_PROFILE" ] && [[ "$IDENTITY" != "Developer ID Application: "* ]]; then
  fail "нотаризация требует Developer ID Application и профиль notarytool"
fi
if [[ "$IDENTITY" == "Developer ID Application: "* ]]; then
  ENTITLEMENTS="entitlements-notarized.plist"
  # Метка времени обязательна для нотаризации: без неё Apple отклоняет пакет.
  # Самоподписи она не нужна и стоит похода на сервер Apple на каждую подпись.
  TIMESTAMP_FLAG="--timestamp"
else
  ENTITLEMENTS="entitlements.plist"
  TIMESTAMP_FLAG="--timestamp=none"
fi
MIN_OS="14.0"

# Общая версия с локальной сборкой. Подстановка проверяется до создания путей.
VERSION="${SMLTLK_VERSION:-$(sed -n '1p' RELEASE_VERSION)}"
BUNDLE_VERSION="${IRIZ_BUNDLE_VERSION:-$VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "версия должна иметь вид 0.2.1"
[[ "$BUNDLE_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "невалидный CFBundleVersion"
case "$HEADLESS" in 1|true) HEADLESS=1 ;; 0|false|"") HEADLESS=0 ;; *) fail "IRIZ_DMG_HEADLESS: только 0 или 1" ;; esac
case "$DMG_FORMAT" in ULFO|UDZO|UDBZ) ;; *) fail "неподдерживаемый формат DMG: $DMG_FORMAT" ;; esac
case "$VARIANTS" in arm64|"arm64 universal") ;; *) fail "IRIZ_RELEASE_VARIANTS: arm64 или 'arm64 universal'" ;; esac

# Все рабочие пути — внутри двух служебных каталогов этого checkout. Ни
# симлинк, ни ../ не должны превратить очистку stage в очистку чужих файлов.
safe_work_path() {
  python3 - "$ROOT" "$1" <<'PY'
import os, sys
root, raw = sys.argv[1:]
path = os.path.abspath(raw)
allowed = [os.path.join(root, name) for name in (".build", "release")]
if path != os.path.realpath(path) or not any(path.startswith(base + os.sep) for base in allowed):
    sys.exit("make_release: рабочий путь должен быть внутри .build/ или release/, без симлинков")
print(path)
PY
}
SCRATCH=$(safe_work_path "$SCRATCH")
DIST=$(safe_work_path "$DIST")
case "$DIST/" in "$SCRATCH/"*) fail "scratch и dist должны быть раздельными" ;; esac
case "$SCRATCH/" in "$DIST/"*) fail "scratch и dist должны быть раздельными" ;; esac
SOURCE_SHA=$(git rev-parse HEAD)
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40,64}$ ]] || fail "не удалось определить commit сборки"
SOURCE_DIRTY=false
[ -z "$(git status --porcelain)" ] || SOURCE_DIRTY=true

mkdir -p "$SCRATCH"
RUN_ROOT=$(mktemp -d "$SCRATCH/run.XXXXXX")
mkdir -p "$RUN_ROOT/dist"
LOG="$RUN_ROOT/make_release.log"
ACTIVE_MOUNT=""
cleanup() {
  local result=$?
  trap - EXIT
  if [ -n "$ACTIVE_MOUNT" ]; then
    hdiutil detach "$ACTIVE_MOUNT" -quiet >> "$LOG" 2>&1 \
      || hdiutil detach "$ACTIVE_MOUNT" -force -quiet >> "$LOG" 2>&1 \
      || { printf 'make_release: не удалось снять собственный том %s\n' "$ACTIVE_MOUNT" >&2; result=1; }
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

say()  { printf '\n=== %s\n' "$*"; }

# Полного вывода сборки в консоли нет намеренно: он тонет в шуме и прячет ошибку.
# Всё уходит в $LOG целиком, наружу вытаскивается grep по строкам ошибок.
run_logged() { # run_logged <человекочитаемый шаг> <команда...>
  local label="$1"; shift
  printf '\n----- %s\n----- %s\n' "$label" "$*" >> "$LOG"
  if ! "$@" >> "$LOG" 2>&1; then
    printf 'make_release: шаг «%s» упал. Строки с ошибками:\n' "$label" >&2
    grep -n -E 'error:|fatal error|ld: |Undefined symbols|cannot |could not ' "$LOG" >&2 || \
      printf '  (строк error: нет — смотрите весь лог)\n' >&2
    printf 'Полный лог: %s\n' "$LOG" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- предпроверки

say "Предпроверки"
[ -f "$ENTITLEMENTS" ] || fail "нет $ENTITLEMENTS"
if [ -n "$NOTARY_PROFILE" ]; then
  command -v xcrun >/dev/null || fail "нет xcrun - нотаризовать нечем"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >> "$LOG" 2>&1 \
    || fail "профиль notarytool «${NOTARY_PROFILE}» не отвечает: заведите его через xcrun notarytool store-credentials"
fi
if [ "$IDENTITY" != "-" ]; then
  security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$IDENTITY\"" >/dev/null \
    || fail "в связке ключей нет сертификата подписи «${IDENTITY}»"
fi
command -v hdiutil >/dev/null || fail "нет hdiutil"
command -v lipo    >/dev/null || fail "нет lipo"
command -v vtool   >/dev/null || fail "нет vtool"
if [ "$HEADLESS" -eq 0 ]; then
  command -v tiffutil >/dev/null || fail "нет tiffutil"
  command -v osascript >/dev/null || fail "нет osascript"
  python3 -c 'import PIL' >/dev/null 2>&1 || fail "для оформления нужен Pillow; IRIZ_DMG_HEADLESS=1 собирает без него"
fi
printf 'версия      : %s (bundle %s)\n' "$VERSION" "$BUNDLE_VERSION"
printf 'подпись     : %s\n' "$IDENTITY"
printf 'права       : %s\n' "$ENTITLEMENTS"
printf 'нотаризация : %s\n' "${NOTARY_PROFILE:-нет}"
printf 'сборка в    : %s\n' "$SCRATCH"
printf 'лог сборки  : %s\n' "$LOG"

# ------------------------------------------------------------------ иконка

say "Иконка"
run_logged "render_marks" bash scripts/render_marks.sh
[ -f .build/AppIcon.icns ] || fail "render_marks.sh не сделал .build/AppIcon.icns"
cp .build/AppIcon.icns "$RUN_ROOT/AppIcon.icns"

# ------------------------------------------------------------------ сборка

# ВАЖНО: свой --scratch-path на каждый вариант. Общий каталог .build держит
# другой процесс, а arm64-only и universal кладут продукт по одному и тому же
# пути внутри своего scratch — смешивать их нельзя.
build_binary() { # build_binary <вариант> <arch...> ; результат в BUILT_BINARY
  local variant="$1"; shift
  local scratch="$SCRATCH/swiftpm-$variant"
  local -a flags=()
  local arch
  for arch in "$@"; do flags+=(--arch "$arch"); done

  run_logged "swift build ($variant: $*)" \
    swift build -c release --product IrizApp --scratch-path "$scratch" "${flags[@]}"

  local bin_path
  bin_path=$(swift build -c release --product IrizApp --scratch-path "$scratch" "${flags[@]}" --show-bin-path 2>>"$LOG") \
    || fail "не удалось получить bin-path для $variant"
  [ -x "$bin_path/IrizApp" ] || fail "после сборки $variant нет бинаря $bin_path/IrizApp"
  BUILT_BINARY="$bin_path/IrizApp"
}

check_archs() { # check_archs <бинарь> <ожидаемые архитектуры через пробел>
  local binary="$1"; shift
  local expected="$*"
  local actual
  actual=$(lipo -archs "$binary")
  printf 'lipo -archs %s\n  -> %s\n' "$binary" "$actual"
  local arch
  for arch in $expected; do
    case " $actual " in
      *" $arch "*) ;;
      *) fail "в $binary нет архитектуры $arch (lipo -archs: «${actual}»)" ;;
    esac
  done
  local found
  for found in $actual; do
    case " $expected " in
      *" $found "*) ;;
      *) fail "в $binary ЛИШНЯЯ архитектура $found (ожидали: «${expected}»)" ;;
    esac
  done
}

check_min_os() { # check_min_os <бинарь> — каждый срез обязан идти на macOS 14
  local binary="$1"
  local report
  report=$(vtool -show-build-version "$binary" 2>&1) || fail "vtool не прочитал $binary"
  printf '%s\n' "$report" >> "$LOG"
  local architectures
  architectures=$(lipo -archs "$binary") || fail "lipo не прочитал $binary"
  python3 - "$MIN_OS" "$architectures" "$report" <<'PY' || fail "minOS/платформа не подтверждены для каждого среза $binary"
import re, sys
limit, arches, report = sys.argv[1:]
versions = re.findall(r"\bminos\s+([0-9.]+)", report)
platforms = re.findall(r"\bplatform\s+(\S+)", report)
def version(value):
    parts = [int(part) for part in value.split('.')]
    return tuple((parts + [0, 0])[:3])
if len(versions) != len(arches.split()) or len(platforms) != len(versions):
    sys.exit(1)
if any(p != "MACOS" for p in platforms) or any(version(v) > version(limit) for v in versions):
    sys.exit(1)
PY
  printf 'minos       : %s (%s)\n' "$(printf '%s\n' "$report" | sed -n 's/.*minos \([0-9.]*\).*/\1/p' | tr '\n' ' ')" "$(basename "$binary")"
}

# ------------------------------------------------------------------ бандл

# Info.plist — тот же, что ставит scripts/build_app.sh, версия подставляется.
write_info_plist() { # write_info_plist <путь к .app>
  cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>iriz</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>iriz</string>
<key>CFBundleDisplayName</key><string>iriz</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
<key>NSMicrophoneUsageDescription</key><string>Микрофон нужен, чтобы превращать твою речь в текст.</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
}

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

make_bundle() { # make_bundle <бинарь> <путь к .app>
  local binary="$1" app="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$binary" "$app/Contents/MacOS/iriz"
  cp "$RUN_ROOT/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  write_info_plist "$app"

  local bin_dir bundle locale
  bin_dir="$(dirname "$binary")"
  [ -d "$bin_dir/IrizApp_IrizCore.bundle" ] || fail "нет ресурсного IrizApp_IrizCore.bundle рядом с $binary"
  for bundle in "$bin_dir"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$app/Contents/Resources/"
  done
  check_meeting_resources "$app"
  for locale in ru en zh-hans; do
    find "$app/Contents/Resources/IrizApp_IrizCore.bundle" -type f \
      -ipath "*/$locale.lproj/Localizable.strings" | grep . >/dev/null \
      || fail "в бандле нет таблицы перевода $locale"
  done

  # Движок распознавания приходит бинарным фреймворком SwiftPM, и в бандл он
  # сам не попадает: сборщик копирует только исполняемый файл.
  #
  # Этот дефект уже ловили живьём 03.09.2026 и починили в scripts/build_app.sh -
  # а здесь он остался. Образ вёз приложение, которое не стартует ВООБЩЕ:
  # «Library not loaded: @rpath/whisper.framework», падение на запуске, без
  # единого внятного сообщения. Владелец увидел это как «не устанавливается».
  # Починка в одном месте из двух - это не починка.
  local framework
  framework="$bin_dir/whisper.framework"
  [ -d "$framework" ] || fail "whisper.framework не найден рядом с $binary"
  mkdir -p "$app/Contents/Frameworks"
  cp -R "$framework" "$app/Contents/Frameworks/"
  local framework_binary="$app/Contents/Frameworks/whisper.framework/whisper"
  [ -f "$framework_binary" ] || fail "нет исполняемого файла whisper.framework/whisper"
  local actual arch
  actual=$(lipo -archs "$framework_binary") || fail "не удалось прочитать архитектуры whisper"
  for arch in $(lipo -archs "$binary"); do
    case " $actual " in *" $arch "*) ;; *) fail "в whisper.framework нет архитектуры $arch" ;; esac
  done
  check_min_os "$framework_binary"
  local load_commands
  load_commands=$(otool -l "$app/Contents/MacOS/iriz") || fail "не удалось прочитать rpath приложения"
  if ! printf '%s\n' "$load_commands" | awk '$1 == "path" && $2 == "@executable_path/../Frameworks" { found=1 } END { exit !found }'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/iriz" >> "$LOG" 2>&1 \
      || fail "не удалось добавить rpath фреймворков"
  fi
  otool -l "$app/Contents/MacOS/iriz" | awk '$1 == "path" && $2 == "@executable_path/../Frameworks" { found=1 } END { exit !found }' \
    || fail "rpath фреймворков отсутствует после упаковки"
  # Фреймворк подписан вендором, и dyld отказывается грузить его в наш процесс:
  # «different Team IDs». --deep чужую подпись не перебивает, поэтому фреймворк
  # подписывается ОТДЕЛЬНО и до подписи бандла.
  codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP_FLAG" \
           "$app/Contents/Frameworks/whisper.framework" >> "$LOG" 2>&1 \
    || fail "подпись фреймворка не прошла (лог: $LOG)"

  codesign --force --deep --sign "$IDENTITY" --options runtime "$TIMESTAMP_FLAG" \
           --entitlements "$ENTITLEMENTS" "$app" >> "$LOG" 2>&1 \
    || fail "подпись $app не прошла (лог: $LOG)"
  codesign --verify --deep --strict "$app" >> "$LOG" 2>&1 \
    || fail "проверка подписи $app не прошла (лог: $LOG)"
  if [[ "$IDENTITY" == "Developer ID Application: "* ]]; then
    run_logged "проверить цепочку Apple" codesign --verify --strict '-R=anchor apple generic' "$app"
  fi

  # Подпись обязана пережить lipo/копирование: срезы сверяем ПОСЛЕ подписи.
  plutil -lint "$app/Contents/Info.plist" >> "$LOG" 2>&1 || fail "Info.plist невалиден"

  # Каждая зависимость по @rpath обязана лежать В БАНДЛЕ. Проверка машинная и
  # стоит здесь, а не в прозе: собрать образ с приложением, которое не
  # стартует, дороже любой другой ошибки сборки - его увидит получатель, а не
  # мы. Именно так и вышло 04.09.2026.
  local missing=0 dependencies
  dependencies=$(otool -L "$app/Contents/MacOS/iriz") || fail "otool не прочитал зависимости приложения"
  while IFS= read -r dep; do
    local rel="${dep#@rpath/}"
    [ -e "$app/Contents/Frameworks/$rel" ] && continue
    echo "  нет в бандле: $rel" >&2
    missing=$((missing + 1))
  done < <(printf '%s\n' "$dependencies" | awk '/@rpath\//{print $1}' | sort -u)
  [ "$missing" -eq 0 ] || fail "в бандле не хватает $missing зависимостей - приложение не запустится"
}

# ------------------------------------------------------------------ образ

# Окно образа делает Finder, а не hdiutil: вид, размер окна, размер значков,
# их места и фоновая картинка живут в .DS_Store тома, и записать их может
# только Finder на смонтированном чтение-запись образе. Поэтому образ
# собирается в два хода: сначала UDRW, потом сжатие в конечный формат.
#
# Координаты значков обязаны совпадать со стрелкой на фоне. Совпадают они
# потому, что приходят из одного места: числа ниже равны числам в
# scripts/render_dmg_background.py, и расхождение ловится глазами на первом же
# собранном образе.
DMG_WINDOW_WIDTH=660
DMG_WINDOW_HEIGHT=420
DMG_ICON_SIZE=128
DMG_APP_X=170
DMG_APP_Y=190
DMG_ALIAS_X=490
DMG_ALIAS_Y=190

style_dmg_window() { # Только собственная точка монтирования, не disk с общим именем.
  osascript - "$1" "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT" "$DMG_ICON_SIZE" \
    "$DMG_APP_X" "$DMG_APP_Y" "$DMG_ALIAS_X" "$DMG_ALIAS_Y" >> "$LOG" 2>&1 <<'APPLESCRIPT'
on run args
set mountPath to item 1 of args
set windowWidth to (item 2 of args) as integer
set windowHeight to (item 3 of args) as integer
set iconSize to (item 4 of args) as integer
set appX to (item 5 of args) as integer
set appY to (item 6 of args) as integer
set aliasX to (item 7 of args) as integer
set aliasY to (item 8 of args) as integer
tell application "Finder"
  tell folder (POSIX file mountPath as alias)
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 200 + windowWidth, 140 + windowHeight}
    set options to the icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to iconSize
    set text size of options to 13
    set background picture of options to POSIX file (mountPath & "/.background/background.tiff")
    set position of item "iriz.app" of container window to {appX, appY}
    set position of item "Applications" of container window to {aliasX, aliasY}
    update without registering applications
    delay 1
    close
  end tell
end tell
end run
APPLESCRIPT
}

# Нотаризация: Apple смотрит пакет и вешает на него билет. Без билета macOS
# у получателя говорит «разработчик не проверен» и требует правый клик.
#
# Билет вешается ДВАЖДЫ и это не перестраховка. Нотаризуем и прикрепляем билет
# сначала к самому приложению, потом к образу. Билет на образе проверяется, пока
# образ смонтирован; вытащенное в /Applications приложение образа больше не
# видит, и без СВОЕГО билета оно проходит проверку только по сети. Человек без
# интернета в этот момент получает отказ на ровном месте.
notarize() { # notarize <путь к .app или .dmg> <человекочитаемое имя>
  [ -n "$NOTARY_PROFILE" ] || return 0
  local target="$1" label="$2"
  local payload="$target"
  # notarytool принимает .zip, .pkg и .dmg. Голый бандл заворачиваем в архив
  # через ditto: он сохраняет символические ссылки и права, обычный zip - нет.
  case "$target" in
    *.app)
      payload="$RUN_ROOT/notarize-$(basename "$target").zip"
      rm -f "$payload"
      run_logged "архив для нотаризации ($label)" \
        ditto -c -k --keepParent "$target" "$payload"
      ;;
  esac
  run_logged "нотаризация ($label)" \
    xcrun notarytool submit "$payload" --keychain-profile "$NOTARY_PROFILE" --wait
  run_logged "прикрепить билет ($label)" xcrun stapler staple "$target"
  run_logged "проверить билет ($label)" xcrun stapler validate "$target"
}

attach_image() {
  local image="$1"; shift
  ACTIVE_MOUNT=$(mktemp -d "$RUN_ROOT/mount.XXXXXX")
  local report
  report=$(hdiutil attach "$image" -mountpoint "$ACTIVE_MOUNT" "$@" -noautoopen -plist 2>>"$LOG") \
    || fail "не удалось смонтировать $image"
  printf '%s\n' "$report" | python3 -c '
import plistlib, sys
data = plistlib.loads(sys.stdin.buffer.read())
if not any(x.get("mount-point") == sys.argv[1] for x in data.get("system-entities", [])):
    sys.exit(1)
' "$ACTIVE_MOUNT" || fail "hdiutil не подтвердил собственную точку монтирования"
}

detach_image() {
  hdiutil detach "$ACTIVE_MOUNT" -quiet >> "$LOG" 2>&1 \
    || hdiutil detach "$ACTIVE_MOUNT" -force -quiet >> "$LOG" 2>&1 \
    || fail "не удалось снять собственный том $ACTIVE_MOUNT"
  rmdir "$ACTIVE_MOUNT" 2>/dev/null || true
  ACTIVE_MOUNT=""
}

build_dmg() { # build_dmg <вариант> <бинарь>; без subshell, чтобы EXIT знал свой mount.
  local variant="$1" binary="$2"
  local stage="$RUN_ROOT/stage-$variant"
  local dmg="$RUN_ROOT/dist/iriz-$VERSION-$variant.dmg"
  local volume="iriz"

  mkdir -p "$stage"
  make_bundle "$binary" "$stage/iriz.app"
  # Билет вешается на приложение ДО сборки образа: после сборки внутрь уже
  # не залезть, а вытащенному в /Applications приложению билет нужен свой.
  notarize "$stage/iriz.app" "приложение $variant"
  ln -s /Applications "$stage/Applications"

  if [ "$HEADLESS" -eq 1 ]; then
    # ponytail: CI не требует Finder и Pillow; локальный выпуск сохраняет оформление.
    run_logged "hdiutil create ($variant, headless)" \
      hdiutil create -volname "$volume" -srcfolder "$stage" -fs HFS+ -format "$DMG_FORMAT" -quiet "$dmg"
  else
    mkdir -p "$stage/.background"
    run_logged "фон образа" python3 scripts/render_dmg_background.py \
      "$RUN_ROOT/bg-$variant.png" "$RUN_ROOT/bg-$variant@2x.png"
    run_logged "tiffutil" tiffutil -cathidpicheck \
      "$RUN_ROOT/bg-$variant.png" "$RUN_ROOT/bg-$variant@2x.png" \
      -out "$stage/.background/background.tiff"
    local rw="$RUN_ROOT/rw-$variant.dmg"
    run_logged "hdiutil create rw ($variant)" \
      hdiutil create -volname "$volume" -srcfolder "$stage" -fs HFS+ -format UDRW -quiet "$rw"
    attach_image "$rw" -readwrite -noverify
    style_dmg_window "$ACTIVE_MOUNT" || fail "Finder не настроил окно образа"
    sync
    detach_image
    run_logged "hdiutil convert ($variant)" \
      hdiutil convert "$rw" -format "$DMG_FORMAT" -o "$dmg" -quiet
    rm -f "$rw"
  fi
  [ -f "$dmg" ] || fail "hdiutil не создал $dmg"
  if [[ "$IDENTITY" == "Developer ID Application: "* ]]; then
    run_logged "подпись образа $variant" codesign --force --sign "$IDENTITY" --timestamp "$dmg"
    run_logged "проверка подписи образа $variant" codesign --verify --strict '-R=anchor apple generic' "$dmg"
  fi
  notarize "$dmg" "образ $variant"
  run_logged "hdiutil verify ($variant)" hdiutil verify "$dmg"

  # Образ обязан монтироваться и содержать то, что мы туда клали, - иначе это
  # «собралось» без «работает». Проверка дешёвая, отказ дорогой.
  attach_image "$dmg" -nobrowse -readonly
  local mount_point="$ACTIVE_MOUNT"
  local mounted_ok=1
  [ -x "$mount_point/iriz.app/Contents/MacOS/iriz" ] || mounted_ok=0
  [ -L "$mount_point/Applications" ] || mounted_ok=0
  [ "$(readlink "$mount_point/Applications")" = /Applications ] || mounted_ok=0
  [ -d "$mount_point/iriz.app/Contents/Resources/IrizApp_IrizCore.bundle" ] || mounted_ok=0
  check_meeting_resources "$mount_point/iriz.app"
  # Вид окна записан - иначе получатель увидит список файлов вместо двух
  # значков со стрелкой, и «перетащи» превратится в «разбирайся сам».
  if [ "$HEADLESS" -eq 0 ]; then
    [ -f "$mount_point/.DS_Store" ] || mounted_ok=0
    [ -f "$mount_point/.background/background.tiff" ] || mounted_ok=0
  fi
  # Ничего лишнего на виду: образ показывает ровно два предмета.
  local visible
  visible=$(ls "$mount_point" | wc -l | tr -d ' ')
  [ "$visible" = "2" ] || { echo "  в образе видно $visible предметов вместо двух" >&2; mounted_ok=0; }
  local mounted_archs=""
  if [ "$mounted_ok" -eq 1 ]; then
    mounted_archs=$(lipo -archs "$mount_point/iriz.app/Contents/MacOS/iriz")
    if [ "$variant" = universal ]; then
      check_archs "$mount_point/iriz.app/Contents/MacOS/iriz" arm64 x86_64
    else
      check_archs "$mount_point/iriz.app/Contents/MacOS/iriz" arm64
    fi
    codesign --verify --deep --strict "$mount_point/iriz.app" >> "$LOG" 2>&1 || mounted_ok=0
    # Вердикт выносит сама система, а не мы. Нотаризованный выпуск обязан
    # получить «accepted» у Gatekeeper - иначе получатель увидит отказ, а мы
    # об этом узнаем от него.
    if [ -n "$NOTARY_PROFILE" ]; then
      spctl -a -vv -t exec "$mount_point/iriz.app" >> "$LOG" 2>&1 \
        || { echo "  Gatekeeper не принял приложение в образе" >&2; mounted_ok=0; }
      xcrun stapler validate "$mount_point/iriz.app" >> "$LOG" 2>&1 \
        || { echo "  на приложении в образе нет билета нотаризации" >&2; mounted_ok=0; }
    fi
  fi
  detach_image
  [ "$mounted_ok" -eq 1 ] || fail "смонтированный $dmg неполон или подпись в нём не проходит (лог: $LOG)"
  printf 'в образе %s: lipo -archs -> %s, подпись проходит\n' "$(basename "$dmg")" "$mounted_archs" >&2

}

for variant in $VARIANTS; do
  say "Сборка и образ $variant"
  if [ "$variant" = universal ]; then
    build_binary "$variant" arm64 x86_64
    check_archs "$BUILT_BINARY" arm64 x86_64
  else
    build_binary "$variant" arm64
    check_archs "$BUILT_BINARY" arm64
  fi
  check_min_os "$BUILT_BINARY"
  build_dmg "$variant" "$BUILT_BINARY"
done

# ------------------------------------------------------------------ итог

say "Итог"
cp "$RUN_ROOT/dist/iriz-$VERSION-arm64.dmg" "$RUN_ROOT/dist/iriz-macos-arm64.dmg"
python3 - "$RUN_ROOT/dist" "$VERSION" "$BUNDLE_VERSION" "$SOURCE_SHA" "$SOURCE_DIRTY" "$IDENTITY" "$NOTARY_PROFILE" <<'PY'
import hashlib, json, pathlib, sys
directory, version, build, sha, dirty, identity, notary = sys.argv[1:]
root = pathlib.Path(directory)
artifacts = []
for path in sorted(root.glob("*.dmg")):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    artifacts.append({"file": path.name, "sha256": digest.hexdigest(), "bytes": path.stat().st_size,
                      "architectures": ["arm64", "x86_64"] if "-universal.dmg" in path.name else ["arm64"]})
mode = "ad-hoc" if identity == "-" else "developer-id" if identity.startswith("Developer ID Application: ") else "self-signed"
manifest = {"version": version, "build_version": build, "source_sha": sha, "source_dirty": dirty == "true",
            "signing": {"identity": identity, "mode": mode, "targets": ["app", "dmg"] if mode == "developer-id" else ["app"]},
            "notarized": bool(notary), "artifacts": artifacts}
(root / "release-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
checksums = [f"{item['sha256']}  {item['file']}" for item in artifacts]
checksums.append(hashlib.sha256((root / "release-manifest.json").read_bytes()).hexdigest() + "  release-manifest.json")
(root / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n", encoding="utf-8")
PY
# Старые артефакты не трогаются, пока все новые варианты не прошли проверки.
mkdir -p "$DIST"
for artifact in "$RUN_ROOT/dist"/*.dmg "$RUN_ROOT/dist/release-manifest.json" "$RUN_ROOT/dist/SHA256SUMS.txt"; do
  mv -f "$artifact" "$DIST/"
done
(cd "$DIST" && shasum -a 256 -c SHA256SUMS.txt)
printf '\nАртефакты: %s\nПриложения и лог: %s\n' "$DIST" "$RUN_ROOT"
if [ -n "$NOTARY_PROFILE" ]; then
  printf 'Developer ID; нотаризация приложения и образа проверена.\n'
else
  printf 'Без нотаризации. Gatekeeper получателя не проверен; подпись: %s.\n' "$IDENTITY"
fi
printf 'Модель распознавания скачивается только по кнопке в приложении.\n'
