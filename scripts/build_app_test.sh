#!/bin/bash
# Проверка установки только в sandbox: подпись, процессы и Swift заменены заглушками.
# Запуск: bash scripts/build_app_test.sh
set -euo pipefail
case "${1:-}" in ""|--selftest) ;; *) echo "usage: build_app_test.sh [--selftest]" >&2; exit 2 ;; esac

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/build-app-test.XXXXXX")"
test_root="$(cd "$test_root" && pwd -P)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/old-app/Contents/MacOS"
cp -R "$repo_root/Sources/IrizDictate/Resources/MeetingMinutes" "$test_root/MeetingMinutes"
minutes_sha=8b4ffde7a7d09c6f3450b2de8667334fe79f544157553c3e81d77456b43807ff
[ "$(shasum -a 256 "$test_root/MeetingMinutes/template.docx" | awk '{print $1}')" = "$minutes_sha" ]
minutes_files=(template.docx data.schema.json fields.json manifest.json README.md template.md
  scripts/fill_template.py scripts/verify_package.py
  fonts/PT_Serif-Web-Regular.ttf fonts/PT_Serif-Web-Bold.ttf fonts/OFL.txt
  docs/formatting.md docs/filling-rules.md docs/filler-usage.md docs/owner-changes.md docs/verification.md
  examples/data.example.json examples/filled.example.docx tests/test_fill_template.py)
printf 'old executable\n' > "$test_root/old-app/Contents/MacOS/iriz"
printf 'keep old resources\n' > "$test_root/old-app/old-marker"
chmod +x "$test_root/old-app/Contents/MacOS/iriz"

# ponytail: один диспетчер вместо библиотеки моков; настоящую установку не запускаем.
cat > "$test_root/bin/stub" <<'STUB'
#!/bin/bash
set -euo pipefail
name="$(basename "$0")"
printf '%s' "$name" >> "$TEST_TRACE"
printf ' <%s>' "$@" >> "$TEST_TRACE"
printf '\n' >> "$TEST_TRACE"
deny() { printf 'forbidden installer test command: %s %s\n' "$name" "$*" >&2; exit 97; }
case "$name" in
  swift)
    case "$*" in *--show-bin-path*) printf '%s/.build/release\n' "$TEST_CASE_ROOT"; exit ;; esac
    mkdir -p .build/release/whisper.framework
    printf 'new executable\n' > .build/release/IrizApp
    printf 'framework\n' > .build/release/whisper.framework/whisper
    chmod +x .build/release/IrizApp .build/release/whisper.framework/whisper
    for locale in ru en zh-hans; do
      resource=".build/release/IrizApp_IrizCore.bundle/$locale.lproj"
      mkdir -p "$resource"
      printf '"fixture" = "new resource";\n' > "$resource/Localizable.strings"
    done
    if [ "${TEST_FAULT:-}" != minutes-bundle ]; then
      minutes='.build/release/IrizApp_IrizDictate.bundle/MeetingMinutes'
      mkdir -p "$(dirname "$minutes")"
      cp -R "$TEST_MINUTES_FIXTURE" "$minutes"
      case "${TEST_FAULT:-}" in
        minutes-file) rm "$minutes/${TEST_MISSING_FILE:?}" ;;
        minutes-digest) printf 'changed template\n' >> "$minutes/template.docx" ;;
        minutes-symlink)
          mv "$minutes/template.docx" "$minutes/original-template.docx"
          ln -s original-template.docx "$minutes/template.docx"
          ;;
        minutes-extra-symlink) ln -s scripts "$minutes/unlisted-link" ;;
      esac
    fi
    case "${TEST_FAULT:-}" in minutes-*) : > "$TEST_CASE_ROOT/injected-fault" ;; esac
    ;;
  codesign)
    if [ "${TEST_FAULT:-}" = signature ] && [ "$1" = --verify ]; then
      : > "$TEST_CASE_ROOT/injected-fault"
      exit 1
    fi
    if [ "${TEST_FAULT:-}" = installed-signature ] && [ "$1" = --verify ] && [ "${!#}" = "$TEST_INSTALL_DIR/iriz.app" ]; then
      : > "$TEST_CASE_ROOT/injected-fault"
      exit 1
    fi
    case "$1" in -dv|-d) printf 'Identifier=ru.iriz.app\nAuthority=smltlk-selfsign\n' ;; esac
    ;;
  otool)
    case "$1" in
      -L) printf '%s:\n\t@rpath/whisper.framework/whisper (compatibility version 1.0.0)\n' "${!#}" ;;
      -l) printf '          cmd LC_RPATH\n         path @executable_path/../Frameworks (offset 12)\n' ;;
      *) deny "$@" ;;
    esac
    ;;
  install_name_tool|plutil|sleep) ;;
  pgrep)
    if [ "$*" = '-x iriz' ] && [ ! -f "$TEST_CASE_ROOT/process-stopped" ]; then printf '4242\n'; exit 0; fi
    exit 1
    ;;
  pkill)
    case "$*" in '-x iriz'|'-x smltlk') : > "$TEST_CASE_ROOT/process-stopped" ;; *) deny "$@" ;; esac
    ;;
  cp|mv|rm|mkdir|touch|ln)
    for argument in "$@"; do
      case "$argument" in /Applications|/Applications/*) deny "system write: $argument" ;; esac
    done
    if [ "$name" = mv ] && [ "${TEST_FAULT:-}" = install-move ]; then
      source=''
      for argument in "$@"; do
        case "$argument" in -*) ;; *) source="$argument"; break ;; esac
      done
      case "$source" in
        "$TEST_CASE_ROOT"/.build/install-app.*/iriz.app)
          case "${!#}" in
            "$TEST_INSTALL_DIR"|"$TEST_INSTALL_DIR/"|"$TEST_INSTALL_DIR/iriz.app")
              : > "$TEST_CASE_ROOT/injected-fault"
              printf 'fixture: install move failed\n' >&2
              exit 1
              ;;
          esac
          ;;
      esac
    fi
    command -p "$name" "$@"
    if [ "$name" = mv ] && [ "${TEST_FAULT:-}" = installed-missing-template ] \
      && [ "${!#}" = "$TEST_INSTALL_DIR/iriz.app" ] && [ ! -f "$TEST_CASE_ROOT/injected-fault" ]; then
      command -p rm "$TEST_INSTALL_DIR/iriz.app/Contents/Resources/IrizApp_IrizDictate.bundle/MeetingMinutes/template.docx"
      : > "$TEST_CASE_ROOT/injected-fault"
    fi
    ;;
  *) deny "$@" ;;
esac
STUB
chmod +x "$test_root/bin/stub"
for command in swift codesign otool install_name_tool plutil pgrep pkill sleep \
  cp mv rm mkdir touch ln security xcrun curl wget open python python3; do
  ln -s stub "$test_root/bin/$command"
done

checks=0
new_case() {
  case_root="$test_root/case-$checks with space"
  mkdir -p "$case_root/scripts" "$case_root/Applications" "$case_root/backups"
  cp -R "$test_root/old-app" "$case_root/Applications/iriz.app"
  printf '1.2.3\n' > "$case_root/RELEASE_VERSION"
  printf '<plist version="1.0"><dict/></plist>\n' > "$case_root/entitlements.plist"
  # Меняем ровно два согласованных пути в КОПИИ. HOME и настоящий installer не меняются.
  [ "$(grep -cFx 'INSTALL_DIR=/Applications' "$repo_root/scripts/build_app.sh")" = 1 ]
  [ "$(grep -cFx 'BACKUP_PARENT="$HOME/Library/Application Support"' "$repo_root/scripts/build_app.sh")" = 1 ]
  sed -e 's|^INSTALL_DIR=/Applications$|INSTALL_DIR="$TEST_INSTALL_DIR"|' \
      -e 's|^BACKUP_PARENT="\$HOME/Library/Application Support"$|BACKUP_PARENT="$TEST_BACKUP_PARENT"|' \
      "$repo_root/scripts/build_app.sh" > "$case_root/scripts/build_app.sh"
  cat > "$case_root/scripts/render_marks.sh" <<'STUB'
#!/bin/bash
mkdir -p .build
printf 'fixture icon\n' > .build/AppIcon.icns
STUB
  : > "$case_root/trace"
}

run_installer() {
  status=0
  (cd "$case_root" && env -i PATH="$test_root/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8 \
    TEST_CASE_ROOT="$case_root" TEST_TRACE="$case_root/trace" \
    TEST_MINUTES_FIXTURE="$test_root/MeetingMinutes" \
    TEST_INSTALL_DIR="$case_root/Applications" TEST_BACKUP_PARENT="$case_root/backups" "$@" \
    /bin/bash "$case_root/scripts/build_app.sh") > "$case_root/output" 2>&1 || status=$?
}

fail() {
  printf 'build_app_test: %s (exit %s)\n' "$*" "$status" >&2
  sed -n '1,100p' "$case_root/output" >&2
  exit 1
}

expect_old_app() {
  diff -r "$test_root/old-app" "$case_root/Applications/iriz.app" >/dev/null \
    || fail 'прежнее приложение изменилось'
}

expect_no_install_activity() {
  if grep -Eq '^(pgrep|pkill) ' "$case_root/trace" \
    || grep '^mv ' "$case_root/trace" | grep -F " <$case_root/Applications/iriz.app>" >/dev/null; then
    fail 'до проверки кандидата тронули установленное приложение или процесс'
  fi
}

for fault in minutes-bundle minutes-digest minutes-symlink minutes-extra-symlink; do
  new_case
  run_installer "TEST_FAULT=$fault"
  [ "$status" = 1 ] || fail "$fault: ожидался отказ пакета протокола"
  reason='пакет протокола MeetingMinutes не найден'
  case "$fault" in
    minutes-digest) reason='SHA-256 шаблона протокола не совпадает с эталоном$' ;;
    *symlink) reason='симлинк в пакете протокола:' ;;
  esac
  grep -Eq "^build_app: $reason" "$case_root/output" || fail "$fault: неверная причина отказа"
  [ -f "$case_root/injected-fault" ] || fail "$fault: сбой пакета не был внедрён"
  expect_old_app
  expect_no_install_activity
  checks=$((checks + 1))
done
for minutes_file in "${minutes_files[@]}"; do
  new_case
  run_installer TEST_FAULT=minutes-file "TEST_MISSING_FILE=$minutes_file"
  [ "$status" = 1 ] || fail "missing $minutes_file: ожидался отказ пакета протокола"
  grep -Fxq "build_app: пакет протокола: отсутствует или пуст $minutes_file" "$case_root/output" \
    || fail 'неверная причина отказа или не назван отсутствующий файл пакета'
  [ -f "$case_root/injected-fault" ] || fail 'пропажа файла пакета не была внедрена'
  expect_old_app
  expect_no_install_activity
  checks=$((checks + 1))
done

new_case
run_installer TEST_FAULT=signature
[ "$status" = 1 ] || fail 'ожидался отказ подписи'
grep -Fxq 'build_app: проверка подготовленной подписи не прошла' "$case_root/output" || fail 'не та причина отказа подписи'
[ -f "$case_root/injected-fault" ] || fail 'сбой подписи не был внедрён'
expect_old_app
expect_no_install_activity
checks=$((checks + 1))

new_case
run_installer TEST_FAULT=install-move
[ "$status" = 1 ] || fail 'ожидался отказ установки'
grep -Fxq 'build_app: не удалось установить подготовленное приложение' "$case_root/output" || fail 'не та причина отказа установки'
[ -f "$case_root/injected-fault" ] || fail 'сбой install mv не был внедрён'
expect_old_app
grep '^mv ' "$case_root/trace" | grep -F " <$case_root/backups/iriz-app-backup." >/dev/null \
  || fail 'откат не переместил прежнюю резервную копию'
checks=$((checks + 1))

new_case
run_installer TEST_FAULT=installed-signature
[ "$status" = 1 ] || fail 'ожидался отказ подписи после установки'
grep -Fxq 'build_app: проверка установленной подписи не прошла' "$case_root/output" \
  || fail 'не та причина отказа установленной подписи'
[ -f "$case_root/injected-fault" ] || fail 'сбой установленной подписи не был внедрён'
expect_old_app
failed_app="$(find "$case_root/backups" -type d -name failed-iriz.app)"
[ -n "$failed_app" ] && cmp -s "$case_root/.build/release/IrizApp" "$failed_app/Contents/MacOS/iriz" \
  || fail 'неудачная новая копия не сохранена'
checks=$((checks + 1))

new_case
run_installer TEST_FAULT=installed-missing-template
[ "$status" = 1 ] || fail 'ожидался отказ неполного пакета после установки'
grep -Fxq 'build_app: пакет протокола: отсутствует или пуст template.docx' "$case_root/output" \
  || fail 'не та причина отказа установленного пакета'
[ -f "$case_root/injected-fault" ] || fail 'пропажа установленного шаблона не была внедрена'
expect_old_app
failed_app="$(find "$case_root/backups" -type d -name failed-iriz.app)"
[ -n "$failed_app" ] && cmp -s "$case_root/.build/release/IrizApp" "$failed_app/Contents/MacOS/iriz" \
  || fail 'неудачная новая копия с неполным пакетом не сохранена'
[ ! -e "$failed_app/Contents/Resources/IrizApp_IrizDictate.bundle/MeetingMinutes/template.docx" ] \
  || fail 'сохранён не тот кандидат с неполным пакетом'
checks=$((checks + 1))

new_case
run_installer
[ "$status" = 0 ] || fail 'ожидалась успешная установка'
cmp -s "$case_root/.build/release/IrizApp" "$case_root/Applications/iriz.app/Contents/MacOS/iriz" \
  || fail 'новый бинарь не установлен'
[ ! -f "$case_root/Applications/iriz.app/old-marker" ] || fail 'установлен старый bundle'
backup="$(find "$case_root/backups" -type d -name iriz.app)"
[ -n "$backup" ] && diff -r "$test_root/old-app" "$backup" >/dev/null || fail 'прежняя копия не сохранена'
[ -f "$case_root/process-stopped" ] || fail 'установщик не остановил прежний процесс'
minutes="$case_root/Applications/iriz.app/Contents/Resources/IrizApp_IrizDictate.bundle/MeetingMinutes"
diff -r "$test_root/MeetingMinutes" "$minutes" >/dev/null || fail 'установлен неполный или изменённый пакет протокола'
[ "$(shasum -a 256 "$minutes/template.docx" | awk '{print $1}')" = "$minutes_sha" ] \
  || fail 'установлен изменённый SHA-256 шаблона протокола'
checks=$((checks + 1))

printf 'build_app_test: %s сценария прошли; /Applications, реальные процессы и подпись не затронуты.\n' "$checks"
