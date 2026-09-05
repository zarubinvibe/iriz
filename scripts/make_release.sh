#!/bin/bash
# Сборка релиза iriz: два DMG в release/dist/ —
#   iriz-<version>-arm64.dmg      (Apple Silicon)
#   iriz-<version>-universal.dmg  (arm64 + x86_64, Intel-маки на macOS 14+)
#
# Отличия от scripts/build_app.sh (тот — установка разработчика в /Applications):
#   • собирает в отдельный scratch-path, чтобы не драться за лок SwiftPM с .build;
#   • собирает universal через `--arch arm64 --arch x86_64` и ПРОВЕРЯЕТ результат
#     через `lipo -archs` — это единственное машинное доказательство поддержки
#     Intel, живого Intel-мака здесь нет;
#   • кладёт в образ ТОЛЬКО приложение и ссылку на Applications: установка -
#     перетаскивание, как у любой программы Apple. Модель распознавания
#     приезжает потом, из самого приложения (шаг знакомства «Скачаем
#     распознавание»): возить в выпуске слепок модели значит раздать всем
#     прошлогоднюю версию и полгигабайта сверху;
#   • ничего не ставит в систему и никуда не отправляет.
#
# Нотаризация включается переменной IRIZ_NOTARY_PROFILE - именем профиля
# учётки notarytool в связке ключей. Заводится один раз:
#
#   xcrun notarytool store-credentials iriz-notary \
#     --apple-id <почта Apple ID> --team-id <TEAMID> --password <пароль-приложения>
#
# С профилем выпуск подписывается настоящим Developer ID, уходит на проверку в
# Apple, получает билет на приложение и на образ, и Gatekeeper у получателя
# молчит. Без профиля всё как раньше: самоподпись, и получатель снимает
# карантин руками (правый клик, «Открыть», ещё раз «Открыть»).
#
# Переменные окружения:
#   SMLTLK_VERSION         — версия (по умолчанию берётся из scripts/build_app.sh)
#   SMLTLK_SIGN_IDENTITY   — имя сертификата (по умолчанию smltlk-selfsign)
#   IRIZ_NOTARY_PROFILE    — профиль notarytool; пусто = без нотаризации
#   SMLTLK_SCRATCH         — каталог сборки (по умолчанию release/build)
#   SMLTLK_DMG_FORMAT      — формат hdiutil (по умолчанию ULFO, lzfse)
#
# Коды возврата: 0 — оба образа собраны; 1 — любая проверка не прошла.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

BUNDLE_ID="ru.iriz.app"
IDENTITY="${SMLTLK_SIGN_IDENTITY:-smltlk-selfsign}"
SCRATCH="${SMLTLK_SCRATCH:-$ROOT/release/build}"
DIST="$ROOT/release/dist"
DMG_FORMAT="${SMLTLK_DMG_FORMAT:-ULFO}"
# Нотаризация включается наличием профиля учётки notarytool в связке ключей
# (создаётся один раз: xcrun notarytool store-credentials). Пусто - выпуск
# собирается как раньше, самоподписью и без похода в Apple. Так решает МАШИНА,
# а не память сборщика: забыть переменную можно, а собрать наполовину
# нотаризованный образ нельзя.
NOTARY_PROFILE="${IRIZ_NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ]; then
  ENTITLEMENTS="entitlements-notarized.plist"
  # Метка времени обязательна для нотаризации: без неё Apple отклоняет пакет.
  # Самоподписи она не нужна и стоит похода на сервер Apple на каждую подпись.
  TIMESTAMP_FLAG="--timestamp"
else
  ENTITLEMENTS="entitlements.plist"
  TIMESTAMP_FLAG="--timestamp=none"
fi
MIN_OS="14.0"

# Версия — из scripts/build_app.sh, чтобы бандлы не разъехались.
VERSION_FROM_BUILD_APP=$(sed -n 's|.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*|\1|p' scripts/build_app.sh | sed -n '1p')
BUNDLE_VERSION_FROM_BUILD_APP=$(sed -n 's|.*<key>CFBundleVersion</key><string>\([^<]*\)</string>.*|\1|p' scripts/build_app.sh | sed -n '1p')
VERSION="${SMLTLK_VERSION:-$VERSION_FROM_BUILD_APP}"
BUNDLE_VERSION="${BUNDLE_VERSION_FROM_BUILD_APP:-1}"

if [ -z "$VERSION" ]; then
  echo "make_release: не удалось прочитать версию из scripts/build_app.sh" >&2
  exit 1
fi

mkdir -p "$SCRATCH" "$DIST"
# Артефакты релиза не должны попадать в индекс git: образы весят сотни мегабайт,
# а публичное дерево собирается по release/WHITELIST.txt, а не по «что лежит».
printf '*\n' > "$DIST/.gitignore"
LOG="$SCRATCH/make_release.log"
: > "$LOG"

say()  { printf '\n=== %s\n' "$*"; }
fail() { printf 'make_release: %s\n' "$*" >&2; exit 1; }

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
    || fail "профиль notarytool «$NOTARY_PROFILE» не отвечает: заведите его через xcrun notarytool store-credentials"
fi
security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" \
  || fail "в связке ключей нет сертификата подписи «$IDENTITY»"
command -v hdiutil >/dev/null || fail "нет hdiutil"
command -v lipo    >/dev/null || fail "нет lipo"
command -v vtool   >/dev/null || fail "нет vtool"
command -v tiffutil >/dev/null || fail "нет tiffutil"
printf 'версия      : %s (bundle %s)\n' "$VERSION" "$BUNDLE_VERSION"
printf 'подпись     : %s\n' "$IDENTITY"
printf 'права       : %s\n' "$ENTITLEMENTS"
printf 'нотаризация : %s\n' "${NOTARY_PROFILE:-нет (самоподпись, получатель снимает карантин руками)}"
printf 'сборка в    : %s\n' "$SCRATCH"
printf 'лог сборки  : %s\n' "$LOG"

# ------------------------------------------------------------------ иконка

say "Иконка"
run_logged "render_marks" bash scripts/render_marks.sh
[ -f .build/AppIcon.icns ] || fail "render_marks.sh не сделал .build/AppIcon.icns"
cp .build/AppIcon.icns "$SCRATCH/AppIcon.icns"

# ------------------------------------------------------------------ сборка

# ВАЖНО: свой --scratch-path на каждый вариант. Общий каталог .build держит
# другой процесс, а arm64-only и universal кладут продукт по одному и тому же
# пути внутри своего scratch — смешивать их нельзя.
build_binary() { # build_binary <вариант> <arch...> ; печатает путь к бинарю
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
  printf '%s\n' "$bin_path/IrizApp"
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
      *) fail "в $binary нет архитектуры $arch (lipo -archs: «$actual»)" ;;
    esac
  done
  local found
  for found in $actual; do
    case " $expected " in
      *" $found "*) ;;
      *) fail "в $binary ЛИШНЯЯ архитектура $found (ожидали: «$expected»)" ;;
    esac
  done
}

check_min_os() { # check_min_os <бинарь> — каждый срез обязан идти на macOS 14
  local binary="$1"
  local report
  report=$(vtool -show-build-version "$binary" 2>&1) || fail "vtool не прочитал $binary"
  printf '%s\n' "$report" >> "$LOG"
  local minos
  for minos in $(printf '%s\n' "$report" | sed -n 's/.*minos \([0-9.]*\).*/\1/p'); do
    # Сравнение по major: 14.0 годится, 15.x — нет (Intel-маки на 14 не запустят).
    case "$minos" in
      14|14.*) ;;
      *) fail "$binary собран под minos $minos, а обещаем macOS $MIN_OS" ;;
    esac
  done
  printf 'minos       : %s (%s)\n' "$(printf '%s\n' "$report" | sed -n 's/.*minos \([0-9.]*\).*/\1/p' | tr '\n' ' ')" "$(basename "$binary")"
}

say "Сборка arm64"
BIN_ARM64=$(build_binary arm64 arm64)
check_archs "$BIN_ARM64" arm64
check_min_os "$BIN_ARM64"

say "Сборка universal (arm64 + x86_64)"
BIN_UNIVERSAL=$(build_binary universal arm64 x86_64)
check_archs "$BIN_UNIVERSAL" arm64 x86_64
check_min_os "$BIN_UNIVERSAL"

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
<key>NSMicrophoneUsageDescription</key><string>Микрофон нужен, чтобы превращать вашу речь в текст.</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
}

make_bundle() { # make_bundle <бинарь> <путь к .app>
  local binary="$1" app="$2"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$binary" "$app/Contents/MacOS/iriz"
  cp "$SCRATCH/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  write_info_plist "$app"

  # Движок распознавания приходит бинарным фреймворком SwiftPM, и в бандл он
  # сам не попадает: сборщик копирует только исполняемый файл.
  #
  # Этот дефект уже ловили живьём 03.09.2026 и починили в scripts/build_app.sh -
  # а здесь он остался. Образ вёз приложение, которое не стартует ВООБЩЕ:
  # «Library not loaded: @rpath/whisper.framework», падение на запуске, без
  # единого внятного сообщения. Владелец увидел это как «не устанавливается».
  # Починка в одном месте из двух - это не починка.
  local framework
  framework="$(find "$SCRATCH" -maxdepth 6 -type d -name whisper.framework -path '*release*' | head -1)"
  [ -n "$framework" ] || fail "whisper.framework не найден в $SCRATCH - приложение не запустится"
  mkdir -p "$app/Contents/Frameworks"
  rm -rf "$app/Contents/Frameworks/whisper.framework"
  cp -R "$framework" "$app/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/iriz" 2>/dev/null || true
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

  # Подпись обязана пережить lipo/копирование: срезы сверяем ПОСЛЕ подписи.
  plutil -lint "$app/Contents/Info.plist" >> "$LOG" 2>&1 || fail "Info.plist невалиден"

  # Каждая зависимость по @rpath обязана лежать В БАНДЛЕ. Проверка машинная и
  # стоит здесь, а не в прозе: собрать образ с приложением, которое не
  # стартует, дороже любой другой ошибки сборки - его увидит получатель, а не
  # мы. Именно так и вышло 04.09.2026.
  local missing=0
  while IFS= read -r dep; do
    local rel="${dep#@rpath/}"
    [ -e "$app/Contents/Frameworks/$rel" ] && continue
    echo "  нет в бандле: $rel" >&2
    missing=$((missing + 1))
  done < <(otool -L "$app/Contents/MacOS/iriz" | awk '/@rpath\//{print $1}' | sort -u)
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

style_dmg_window() { # style_dmg_window <имя тома>
  local volume="$1"
  osascript >> "$LOG" 2>&1 <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, $((200 + DMG_WINDOW_WIDTH)), $((140 + DMG_WINDOW_HEIGHT))}
    set options to the icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to $DMG_ICON_SIZE
    set text size of options to 13
    set background picture of options to POSIX file "/Volumes/$volume/.background/background.tiff"
    set position of item "iriz.app" of container window to {$DMG_APP_X, $DMG_APP_Y}
    set position of item "Applications" of container window to {$DMG_ALIAS_X, $DMG_ALIAS_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
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
      payload="$SCRATCH/notarize-$(basename "$target").zip"
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

build_dmg() { # build_dmg <вариант> <бинарь> ; печатает путь к dmg
  local variant="$1" binary="$2"
  local stage="$SCRATCH/stage-$variant"
  local dmg="$DIST/iriz-$VERSION-$variant.dmg"
  local volume="iriz"

  rm -rf "$stage"; mkdir -p "$stage/.background"
  make_bundle "$binary" "$stage/iriz.app"
  # Билет вешается на приложение ДО сборки образа: после сборки внутрь уже
  # не залезть, а вытащенному в /Applications приложению билет нужен свой.
  notarize "$stage/iriz.app" "приложение $variant"
  ln -s /Applications "$stage/Applications"

  # Фон в двух плотностях одним TIFF: на ретине однократный PNG размывается,
  # а Finder умеет читать многослойный TIFF как HiDPI.
  run_logged "фон образа" python3 scripts/render_dmg_background.py \
    "$SCRATCH/bg-$variant.png" "$SCRATCH/bg-$variant@2x.png"
  run_logged "tiffutil" tiffutil -cathidpicheck \
    "$SCRATCH/bg-$variant.png" "$SCRATCH/bg-$variant@2x.png" \
    -out "$stage/.background/background.tiff"

  # Первый ход: образ, в который можно писать.
  local rw="$SCRATCH/rw-$variant.dmg"
  rm -f "$rw"
  run_logged "hdiutil create rw ($variant)" \
    hdiutil create -volname "$volume" -srcfolder "$stage" \
      -fs HFS+ -format UDRW -ov -quiet "$rw"

  # Том монтируется ВИДИМЫМ: Finder не умеет открывать окно тома, которого он
  # не видит, а без окна не запишется ни вид, ни фон.
  local mounted="/Volumes/$volume"
  # Хвост прошлого прогона убирается сам: иначе система смонтирует том под
  # именем «iriz 1», Finder будет наряжать не тот том, а проверка вида упадёт
  # без единого намёка на причину.
  if [ -d "$mounted" ]; then
    hdiutil detach "$mounted" -force -quiet >> "$LOG" 2>&1 || true
  fi
  run_logged "hdiutil attach rw ($variant)" \
    hdiutil attach "$rw" -mountpoint "$mounted" -readwrite -noverify -noautoopen -quiet
  [ -d "$mounted" ] || fail "том «$volume» не смонтировался"
  style_dmg_window "$volume"
  sync
  hdiutil detach "$mounted" -quiet >> "$LOG" 2>&1 \
    || hdiutil detach "$mounted" -force -quiet >> "$LOG" 2>&1

  # Второй ход: сжатие в конечный формат.
  rm -f "$dmg"
  run_logged "hdiutil convert ($variant)" \
    hdiutil convert "$rw" -format "$DMG_FORMAT" -o "$dmg" -ov -quiet
  [ -f "$dmg" ] || fail "hdiutil не создал $dmg"
  rm -f "$rw"
  notarize "$dmg" "образ $variant"

  # Образ обязан монтироваться и содержать то, что мы туда клали, - иначе это
  # «собралось» без «работает». Проверка дешёвая, отказ дорогой.
  local mount_point="$SCRATCH/mnt-$variant"
  rm -rf "$mount_point"; mkdir -p "$mount_point"
  run_logged "hdiutil attach ($variant)" \
    hdiutil attach "$dmg" -mountpoint "$mount_point" -nobrowse -readonly -quiet
  local mounted_ok=1
  [ -x "$mount_point/iriz.app/Contents/MacOS/iriz" ] || mounted_ok=0
  [ -L "$mount_point/Applications" ] || mounted_ok=0
  # Вид окна записан - иначе получатель увидит список файлов вместо двух
  # значков со стрелкой, и «перетащи» превратится в «разбирайся сам».
  [ -f "$mount_point/.DS_Store" ] || mounted_ok=0
  [ -f "$mount_point/.background/background.tiff" ] || mounted_ok=0
  # Ничего лишнего на виду: образ показывает ровно два предмета.
  local visible
  visible=$(ls "$mount_point" | wc -l | tr -d ' ')
  [ "$visible" = "2" ] || { echo "  в образе видно $visible предметов вместо двух" >&2; mounted_ok=0; }
  local mounted_archs=""
  if [ "$mounted_ok" -eq 1 ]; then
    mounted_archs=$(lipo -archs "$mount_point/iriz.app/Contents/MacOS/iriz")
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
  hdiutil detach "$mount_point" -quiet >> "$LOG" 2>&1 || hdiutil detach "$mount_point" -force -quiet >> "$LOG" 2>&1
  rm -rf "$mount_point"
  [ "$mounted_ok" -eq 1 ] || fail "смонтированный $dmg неполон или подпись в нём не проходит (лог: $LOG)"
  printf 'в образе %s: lipo -archs -> %s, подпись проходит\n' "$(basename "$dmg")" "$mounted_archs" >&2

  printf '%s\n' "$dmg"
}

say "Образ arm64"
DMG_ARM64=$(build_dmg arm64 "$BIN_ARM64")

say "Образ universal"
DMG_UNIVERSAL=$(build_dmg universal "$BIN_UNIVERSAL")

# ------------------------------------------------------------------ итог

say "Итог"
: > "$DIST/SHA256SUMS.txt"
for dmg in "$DMG_ARM64" "$DMG_UNIVERSAL"; do
  bytes=$(stat -f %z "$dmg")
  human=$(du -h "$dmg" | awk '{print $1}')
  digest=$(shasum -a 256 "$dmg" | awk '{print $1}')
  printf '%s  %s\n' "$digest" "$(basename "$dmg")" >> "$DIST/SHA256SUMS.txt"
  printf '\n%s\n  размер   : %s (%s байт)\n  sha256   : %s\n' \
    "$dmg" "$human" "$bytes" "$digest"
done
printf '\n  контрольные суммы: %s\n' "$DIST/SHA256SUMS.txt"

printf '\n  Нотаризации нет: Apple Developer ID отсутствует, подпись «%s» самодельная.\n' "$IDENTITY"
printf '  Получатель снимает карантин руками: правый клик по приложению, «Открыть».\n'
printf '  Модель распознавания приложение скачивает само при первом запуске.\n\n'
